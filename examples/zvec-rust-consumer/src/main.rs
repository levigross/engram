//! A Rust program that uses zvec in its own process through the `zvec-rust` crate: a collection
//! with a scalar field and an HNSW index of vectors, written, searched with and without a
//! filter, fetched by key, deleted from, optimized, closed and opened again, and the paths that
//! fail. Anything not as expected is a non-zero exit. The arguments are the version that the
//! library must report, and a directory to keep the collection in.

use std::error::Error;
use std::path::Path;
use std::process::ExitCode;

use zvec_rust::{
    initialize, is_initialized, shutdown, version, Collection, CollectionSchema, DataType, Doc,
    FieldSchema, IndexParams, MetricType, SearchQuery,
};

type Outcome<T = ()> = Result<T, Box<dyn Error>>;

const DIM: usize = 4;
const DOCS: usize = 100;
/// The document that the searches are for, and the one that is deleted.
const DELETED: usize = 42;
/// The document that the search before and after the collection is closed is for.
const KEPT: usize = 7;

fn check(condition: bool, what: impl Into<String>) -> Outcome {
    if condition {
        Ok(())
    } else {
        Err(format!("FAILED: {}", what.into()).into())
    }
}

fn pk(i: usize) -> String {
    format!("doc_{i}")
}

/// The vector of document `i`; no two are alike, so each is the nearest of itself.
fn vector(i: usize) -> [f32; DIM] {
    [
        i as f32 * 0.1,
        (i % 7) as f32,
        (i % 11) as f32 * 0.5,
        (i % 13) as f32 * 0.25,
    ]
}

fn schema() -> zvec_rust::Result<CollectionSchema> {
    CollectionSchema::builder("consumer")
        .add_indexed_field("price", DataType::Int32, IndexParams::invert(true, false)?)
        .add_field(FieldSchema::new("label", DataType::String, false, 0)?)
        .add_vector_field(
            "embedding",
            DataType::VectorFp32,
            DIM as u32,
            IndexParams::hnsw(MetricType::L2, 16, 200)?,
        )
        .build()
}

fn document(i: usize) -> zvec_rust::Result<Doc> {
    let mut doc = Doc::new()?;
    doc.try_set_pk(&pk(i))?;
    doc.add_i32("price", i as i32)?;
    doc.add_string("label", &format!("item {i}"))?;
    doc.add_vector_f32("embedding", &vector(i))?;
    Ok(doc)
}

/// The five documents nearest to the vector of document `i`, with the filter if there is one.
fn nearest(c: &Collection, i: usize, filter: Option<&str>) -> zvec_rust::Result<Vec<Doc>> {
    let mut query = SearchQuery::new("embedding", &vector(i), 5)?;
    query.set_output_fields(&["price"])?;
    if let Some(filter) = filter {
        query.set_filter(filter)?;
    }
    c.query(&query)
}

fn contains(hits: &[Doc], i: usize) -> bool {
    hits.iter().any(|hit| hit.get_pk() == Some(pk(i).as_str()))
}

/// The hits are in the order of their distance, and the nearest is the document itself.
fn check_top(hits: &[Doc], i: usize) -> Outcome {
    let top = hits
        .first()
        .ok_or("a search for a stored vector found nothing")?;
    check(
        top.get_pk() == Some(pk(i).as_str()),
        format!("{} is not its own nearest", pk(i)),
    )?;
    check(
        top.get_score().abs() < 1e-4,
        format!("{} is at distance {}", pk(i), top.get_score()),
    )?;
    let ascending = hits
        .windows(2)
        .all(|w| w[0].get_score() <= w[1].get_score());
    check(ascending, "the distances of the hits do not ascend")
}

fn search(c: &Collection) -> Outcome {
    let key = pk(DELETED);
    let hits = nearest(c, DELETED, None)?;
    check_top(&hits, DELETED)?;
    let found: Vec<_> = hits
        .iter()
        .map(|hit| (hit.get_pk(), hit.get_score()))
        .collect();
    println!("nearest 5 of {key}: {found:?}");

    // 50 documents have a price of 50 or more, and the one searched for is not among them
    let filtered = nearest(c, DELETED, Some("price >= 50"))?;
    check(!filtered.is_empty(), "the filter price >= 50 found nothing")?;
    check(
        !contains(&filtered, DELETED),
        format!("{key} has a price below 50"),
    )?;
    for hit in &filtered {
        let price = hit.get_i32("price")?.ok_or("a hit has no price")?;
        check(
            price >= 50,
            format!("{} has price {price}", hit.get_pk().unwrap_or("?")),
        )?;
    }
    println!(
        "nearest {} of {key} with price >= 50: all of them",
        filtered.len()
    );

    let fetched = c.fetch(&[key.as_str()])?;
    let [doc] = fetched.as_slice() else {
        return Err(format!("fetching one key gave {} documents", fetched.len()).into());
    };
    check(
        doc.get_pk() == Some(key.as_str()),
        "the fetched document has another key",
    )?;
    check(
        doc.get_i32("price")? == Some(DELETED as i32),
        "price does not round-trip",
    )?;
    let label = format!("item {DELETED}");
    check(
        doc.get_string("label")?.as_deref() == Some(label.as_str()),
        "label does not",
    )?;
    let stored = doc.get_vector_f32("embedding")?;
    check(
        stored.as_deref() == Some(&vector(DELETED)[..]),
        "vector does not",
    )?;
    println!("fetched {key} and its fields round-trip");
    Ok(())
}

fn delete(c: &Collection) -> Outcome {
    let key = pk(DELETED);
    let deleted = c.delete(&[key.as_str()])?;
    check(
        deleted.success_count == 1 && deleted.error_count == 0,
        "the delete failed",
    )?;
    check(
        c.fetch(&[key.as_str()])?.is_empty(),
        "a deleted document is fetched",
    )?;
    check(
        !contains(&nearest(c, DELETED, None)?, DELETED),
        "a deleted document is found",
    )?;
    let count = c.stats()?.doc_count;
    check(
        count == DOCS as u64 - 1,
        format!("{count} documents after a delete of {DOCS}"),
    )?;
    println!("deleted {key}: neither fetched nor found, {count} documents are left");
    Ok(())
}

fn run(expected: &str, scratch: &Path) -> Outcome {
    let library = version();
    println!("library version {library}");
    check(
        library == expected,
        format!("the library is {library:?}, expected {expected:?}"),
    )?;
    initialize(None)?;
    check(is_initialized(), "the library is not initialized")?;

    let path = scratch.join("collection");
    let path = path.to_str().ok_or("the directory is not UTF-8")?;
    let c = Collection::create_and_open(path, &schema()?, None)?;
    let docs = (0..DOCS)
        .map(document)
        .collect::<zvec_rust::Result<Vec<_>>>()?;
    let written = c.insert(&docs.iter().collect::<Vec<_>>())?;
    check(
        written.success_count == DOCS as u64 && written.error_count == 0,
        "an insert failed",
    )?;
    c.flush()?;
    let count = c.stats()?.doc_count;
    check(
        count == DOCS as u64,
        format!("{count} documents after {DOCS} inserts"),
    )?;
    println!(
        "created a collection of price, label and a {DIM}-d vector (L2, HNSW): {count} documents"
    );

    search(&c)?;
    delete(&c)?;

    c.optimize()?;
    c.flush()?;
    let (count, top) = (c.stats()?.doc_count, nearest(&c, KEPT, None)?);
    check_top(&top, KEPT)?;
    println!(
        "optimized: {count} documents, {} still its own nearest",
        pk(KEPT)
    );

    c.try_close()?;
    let c = Collection::open(path, None)?;
    let reopened = c.stats()?.doc_count;
    check(
        reopened == count,
        format!("{reopened} documents after reopening, {count} before"),
    )?;
    let hits = nearest(&c, KEPT, None)?;
    check_top(&hits, KEPT)?;
    check(
        hits.len() == top.len(),
        format!("{} hits after reopening, {} before", hits.len(), top.len()),
    )?;
    check(
        !contains(&nearest(&c, DELETED, None)?, DELETED),
        "reopening undid the delete",
    )?;
    println!("closed and reopened: {reopened} documents, the same nearest hit");

    // errors are values, not panics
    let missing = scratch.join("missing");
    let missing = missing.to_str().ok_or("the directory is not UTF-8")?;
    let Err(error) = Collection::open(missing, None) else {
        return Err("a collection that is not there was opened".into());
    };
    println!("a collection that is not there: {error}");
    let malformed = SearchQuery::new("embedding", &vector(0), 5).and_then(|mut query| {
        query.set_filter("price >>> 50 (((")?;
        c.query(&query)
    });
    let Err(error) = malformed else {
        return Err("a malformed filter was accepted".into());
    };
    println!("a malformed filter: {error}");

    drop(c);
    shutdown()?;
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [expected, scratch] = args.as_slice() else {
        eprintln!("usage: zvec-rust-consumer LIBRARY_VERSION DIRECTORY");
        return ExitCode::from(2);
    };
    match run(expected, Path::new(scratch)) {
        Ok(()) => {
            println!("zvec-rust-consumer OK");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("zvec-rust-consumer: {error}");
            ExitCode::FAILURE
        }
    }
}
