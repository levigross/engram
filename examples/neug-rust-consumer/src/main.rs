//! A Rust program that uses NeuG in its own process through the `neug` crate: a graph, a
//! question of two hops, every kind of cell, the extensions loaded by name, transactions, and
//! the paths that fail. Anything not as expected is a non-zero exit. The extensions to load are
//! the arguments.

use std::error::Error;

use neug::{ColumnType, Database, ErrorKind, Params, TxMode};

type Outcome = Result<(), Box<dyn Error>>;

fn check(condition: bool, what: &str) -> Outcome {
    if condition {
        Ok(())
    } else {
        Err(format!("FAILED: {what}").into())
    }
}

fn count(conn: &mut neug::Connection, cypher: &str) -> neug::Result<usize> {
    Ok(conn.query(cypher)?.len())
}

fn run() -> Outcome {
    println!(
        "NeuG {} through version {} of the C interface",
        neug::version(),
        neug::abi_version()
    );

    let db = Database::in_memory()?;
    let mut conn = db.connect()?;

    // a database that is read and written has one connection
    match db.connect() {
        Err(e) => {
            // the engine throws for it: an exception, whose text ends with the code of NeuG
            check(
                e.kind() == ErrorKind::Exception,
                "a second connection is an exception",
            )?;
            check(
                e.message().contains("Error Code: 4001"),
                "its text has the code of NeuG",
            )?;
            println!("a second connection: {e}");
        }
        Ok(_) => return Err("a second connection was allowed".into()),
    }

    for extension in std::env::args().skip(1) {
        conn.query(&format!("LOAD {extension}"))?;
        println!("loaded {extension}");
    }
    check(
        conn.query("LOAD no_such_extension").is_err(),
        "an extension that is not there",
    )?;

    conn.query(
        "CREATE NODE TABLE person(id INT64, name STRING, age INT64, score DOUBLE, ok BOOL, \
         PRIMARY KEY(id));",
    )?;
    conn.query("CREATE REL TABLE knows(FROM person TO person);")?;
    conn.query("CREATE (:person {id: 1, name: 'Alice', age: 30, score: 1.5, ok: true});")?;
    conn.query("CREATE (:person {id: 2, name: 'Bob', age: 25, score: 2.5, ok: false});")?;
    conn.query("CREATE (:person {id: 3, name: 'Carol', age: 41, score: 3.5, ok: true});")?;
    conn.query("CREATE (:person {id: 4, name: 'Dan'});")?;
    conn.query("MATCH (a:person {id: 1}), (b:person {id: 2}) CREATE (a)-[:knows]->(b);")?;
    conn.query("MATCH (a:person {id: 2}), (b:person {id: 3}) CREATE (a)-[:knows]->(b);")?;

    // two hops, typed cells, and the name of a column without the engine's number
    let mut hops = conn.query(
        "MATCH (a:person {id: 1})-[:knows]->(:person)-[:knows]->(c:person) RETURN c.name, c.age;",
    )?;
    check(hops.len() == 1, "one friend of a friend")?;
    check(
        hops.columns()[0].ty == ColumnType::String,
        "the name is a string",
    )?;
    check(
        hops.columns()[1].ty == ColumnType::Int64,
        "the age is an int64",
    )?;
    {
        let mut rows = hops.rows();
        let row = rows.next().ok_or("no row")?;
        check(row.get::<String>(0)? == "Carol", "Carol")?;
        check(row.get::<i64>(1)? == 41, "41")?;
        check(
            row.get_by_name::<String>("c.name")? == "Carol",
            "by the name of the column",
        )?;
        check(
            row.get::<Option<i64>>(1)? == Some(41),
            "an Option that is there",
        )?;
        println!("friend of a friend of Alice: Carol, 41");
        check(rows.next().is_none(), "the end")?;
    }

    // every row; a property a node was made without is the default of the type, not NULL
    let mut people =
        conn.query("MATCH (n:person) RETURN n.id, n.name, n.age, n.score, n.ok ORDER BY n.id;")?;
    let mut seen = 0usize;
    let mut total = 0.0;
    let mut rows = people.rows();
    while let Some(row) = rows.next() {
        let id = row.get::<i64>(0)?;
        check(id == seen as i64 + 1, "in order")?;
        let age = row.get::<i64>(2)?;
        check(age == [30, 25, 41, 0][seen], "the age, or 0 for Dan")?;
        total += row.get::<f64>(3)?;
        check(
            row.get::<bool>(4)? == (id == 1 || id == 3),
            "the flag, or false for Dan",
        )?;
        check(!row.is_null(2)?, "Dan's age is not NULL")?;
        seen += 1;
    }
    check(seen == 4 && total == 7.5, "four people")?;

    // a genuine NULL, read as an Option, and as a plain type it is an error
    let mut none = conn.query("OPTIONAL MATCH (n:person {id: 77}) RETURN n.name, n.age;")?;
    {
        let mut rows = none.rows();
        let row = rows.next().ok_or("no row")?;
        check(row.get::<Option<String>>(0)?.is_none(), "NULL as an Option")?;
        check(
            row.get::<Option<i64>>(1)?.is_none(),
            "NULL as an Option, an integer",
        )?;
        check(
            row.get::<String>(0).err().map(|e| e.kind()) == Some(ErrorKind::Null),
            "NULL as a String",
        )?;
        check(row.is_null(0)?, "is_null")?;
    }

    // wrong uses of a cell are errors with a kind
    {
        let mut rows = people.rows();
        let row = rows.next().ok_or("no row")?;
        check(
            row.get::<f32>(1).err().map(|e| e.kind()) == Some(ErrorKind::Type),
            "a string as a float",
        )?;
        check(
            row.get::<i64>(99).err().map(|e| e.kind()) == Some(ErrorKind::Column),
            "a column that is not there",
        )?;
        check(
            row.get_by_name::<i64>("nope").err().map(|e| e.kind()) == Some(ErrorKind::Column),
            "a name that is not there",
        )?;
    }

    // parameters
    let mut named = conn.query_with(
        "MATCH (n:person) WHERE n.id = $id RETURN n.name;",
        neug::Access::Read,
        &Params::new().with("id", 2),
    )?;
    check(
        named.rows().next().ok_or("no row")?.get::<String>(0)? == "Bob",
        "a parameter",
    )?;

    // a transaction that is rolled back, one that is dropped, one that is committed
    check(!conn.in_transaction(), "no transaction")?;
    {
        let mut tx = conn.begin(TxMode::ReadWrite)?;
        tx.query("CREATE (:person {id: 9, name: 'Zed', age: 1});")?;
        check(
            tx.query("MATCH (n:person {id: 9}) RETURN n.id;")?.len() == 1,
            "seen inside",
        )?;
        tx.rollback()?;
    }
    check(
        count(&mut conn, "MATCH (n:person {id: 9}) RETURN n.id;")? == 0,
        "rolled back",
    )?;
    {
        let mut tx = conn.begin(TxMode::ReadWrite)?;
        tx.query("CREATE (:person {id: 11, name: 'Lee', age: 3});")?;
        // dropped: rolled back
    }
    check(
        count(&mut conn, "MATCH (n:person {id: 11}) RETURN n.id;")? == 0,
        "dropped, so rolled back",
    )?;
    {
        let mut tx = conn.begin(TxMode::ReadWrite)?;
        tx.query("CREATE (:person {id: 10, name: 'Kim', age: 2});")?;
        tx.commit()?;
    }
    check(
        count(&mut conn, "MATCH (n:person {id: 10}) RETURN n.id;")? == 1,
        "committed",
    )?;

    // a wrong query is an error of the engine, with its code and its words
    let e = conn
        .query("MATCH (n:no_such_table) RETURN n;")
        .err()
        .ok_or("a wrong query worked")?;
    check(
        e.kind() == ErrorKind::Engine && e.code() == 5001,
        "the code of the engine",
    )?;
    check(
        e.message().contains("no_such_table"),
        "its message names the table",
    )?;
    println!("a wrong query: {e}");

    // a result and a connection can move to another thread
    let answer = std::thread::spawn(move || {
        let mut conn = conn;
        conn.query("MATCH (n:person) RETURN n.id;").map(|r| r.len())
    })
    .join()
    .map_err(|_| "the thread panicked")??;
    // the four of the graph, and the one that was committed (not the two that were not)
    check(answer == 5, "five people from another thread")?;

    drop(db);
    println!("neug rust consumer OK");
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
