//! NeuG, an embedded graph database, in your process.
//!
//! Safe bindings to its C interface (`neug_c.h`, the package `neug-c`). The engine runs inside
//! the program: there is no server and no other process.
//!
//! ```no_run
//! # fn main() -> neug::Result<()> {
//! let db = neug::Database::in_memory()?;
//! let mut conn = db.connect()?;
//! conn.query("CREATE NODE TABLE person(id INT64, name STRING, PRIMARY KEY(id));")?;
//! conn.query("CREATE (:person {id: 1, name: 'Alice'});")?;
//! let mut result = conn.query("MATCH (n:person) RETURN n.id, n.name;")?;
//! let mut rows = result.rows();
//! while let Some(row) = rows.next() {
//!     println!("{} {}", row.get::<i64>(0)?, row.get::<String>(1)?);
//! }
//! # Ok(()) }
//! ```
//!
//! What to know:
//! - A database that is read and written has ONE connection at a time; a second `connect` is
//!   an error until the first is dropped.
//! - A property that a node was made without is not NULL but the default of its type. A NULL
//!   is what an `OPTIONAL MATCH` that finds nothing gives; read it as an `Option`.
//! - The engine names the columns of a result with the number of a variable in front
//!   (`_7_c.name`); [`Row::get_by_name`] matches the name without it.
//! - Some conditions inside the engine end the process (a failed `CHECK`), which no binding can
//!   catch. A program that cannot afford that runs the engine in a process of its own.
//! - Extensions are loaded by name with the query `LOAD parquet`; where they are is built into
//!   the library.

mod error;
mod params;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

use neug_sys as sys;

pub use error::{Error, ErrorKind, Result};
pub use params::{Param, Params};

use error::check;

/// The version of NeuG the library was built against.
pub fn version() -> &'static str {
    unsafe { CStr::from_ptr(sys::neug_c_version()) }
        .to_str()
        .unwrap_or("unknown")
}

/// The version of the C interface the library implements (these bindings are of
/// [`neug_sys::ABI_VERSION`]; `Database::open` refuses a library of another one).
pub fn abi_version() -> u32 {
    unsafe { sys::neug_c_abi_version() }
}

/// How a database is opened.
#[derive(Debug, Clone)]
pub struct Config {
    path: Option<PathBuf>,
    max_threads: u32,
    read_only: bool,
    checkpoint_on_close: bool,
}

impl Config {
    /// A database in memory: a temporary directory that is gone when the database is closed
    /// (`NEUG_DB_TMP_DIR` says where, by default `/tmp`).
    pub fn in_memory() -> Self {
        Config {
            path: None,
            max_threads: 0,
            read_only: false,
            checkpoint_on_close: true,
        }
    }

    /// A database in a directory.
    pub fn at(path: impl Into<PathBuf>) -> Self {
        Config {
            path: Some(path.into()),
            ..Config::in_memory()
        }
    }

    pub fn read_only(mut self, read_only: bool) -> Self {
        self.read_only = read_only;
        self
    }

    /// The threads of the engine; 0 is as many as the machine has.
    pub fn max_threads(mut self, threads: u32) -> Self {
        self.max_threads = threads;
        self
    }

    pub fn checkpoint_on_close(mut self, yes: bool) -> Self {
        self.checkpoint_on_close = yes;
        self
    }
}

impl Default for Config {
    fn default() -> Self {
        Config::in_memory()
    }
}

struct DbHandle(*mut sys::neug_db);

// The interface says so: opening, closing and freeing are serialized in the library, and
// `neug_conn_open` may be called from several threads.
unsafe impl Send for DbHandle {}
unsafe impl Sync for DbHandle {}

impl Drop for DbHandle {
    fn drop(&mut self) {
        unsafe { sys::neug_db_free(self.0) }
    }
}

/// An open database. It is closed when it and all its connections are dropped.
pub struct Database {
    handle: Arc<DbHandle>,
}

impl Database {
    pub fn open(config: &Config) -> Result<Database> {
        let abi = abi_version();
        if abi != sys::ABI_VERSION {
            return Err(Error::new(
                sys::NEUG_E_ABI,
                format!(
                    "libneug_c implements version {abi} of the interface, these bindings are of \
                     version {}",
                    sys::ABI_VERSION
                ),
            ));
        }
        let path = match &config.path {
            Some(path) => Some(
                CString::new(path.as_os_str().as_bytes())
                    .map_err(|_| Error::new(sys::NEUG_E_PARAMETERS, "the path has a NUL in it"))?,
            ),
            None => None,
        };
        let mut options = std::mem::MaybeUninit::<sys::neug_open_options>::uninit();
        let options = unsafe {
            sys::neug_open_options_init(options.as_mut_ptr());
            options.assume_init_mut()
        };
        options.path = path.as_ref().map_or(ptr::null(), |p| p.as_ptr());
        options.max_threads = config.max_threads as i32;
        options.read_only = config.read_only.into();
        options.checkpoint_on_close = config.checkpoint_on_close.into();

        let mut db = ptr::null_mut();
        let mut err = ptr::null_mut();
        let status = unsafe { sys::neug_db_open(options, &mut db, &mut err) };
        check(status, err)?;
        Ok(Database {
            handle: Arc::new(DbHandle(db)),
        })
    }

    /// A database in memory.
    pub fn in_memory() -> Result<Database> {
        Database::open(&Config::in_memory())
    }

    /// A connection. A database that is read and written has one at a time.
    pub fn connect(&self) -> Result<Connection> {
        let mut conn = ptr::null_mut();
        let mut err = ptr::null_mut();
        let status = unsafe { sys::neug_conn_open(self.handle.0, &mut conn, &mut err) };
        check(status, err)?;
        Ok(Connection {
            ptr: conn,
            _db: Arc::clone(&self.handle),
        })
    }
}

/// How a query is going to use the database; `Infer` lets NeuG tell.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    Infer,
    Read,
    Insert,
    Update,
    Schema,
}

impl Access {
    fn raw(self) -> sys::neug_access {
        match self {
            Access::Infer => sys::NEUG_ACCESS_INFER,
            Access::Read => sys::NEUG_ACCESS_READ,
            Access::Insert => sys::NEUG_ACCESS_INSERT,
            Access::Update => sys::NEUG_ACCESS_UPDATE,
            Access::Schema => sys::NEUG_ACCESS_SCHEMA,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TxMode {
    ReadOnly,
    ReadWrite,
}

/// A connection to a database. It can move between threads, and is used by one at a time.
pub struct Connection {
    ptr: *mut sys::neug_conn,
    // the database stays open while a connection is
    _db: Arc<DbHandle>,
}

unsafe impl Send for Connection {}

impl Drop for Connection {
    fn drop(&mut self) {
        unsafe { sys::neug_conn_free(self.ptr) }
    }
}

impl Connection {
    pub fn query(&mut self, cypher: &str) -> Result<QueryResult> {
        self.run(cypher, Access::Infer, None)
    }

    pub fn query_with(
        &mut self,
        cypher: &str,
        access: Access,
        params: &Params,
    ) -> Result<QueryResult> {
        self.run(cypher, access, Some(params.to_json()))
    }

    fn run(&mut self, cypher: &str, access: Access, params: Option<String>) -> Result<QueryResult> {
        let cypher = CString::new(cypher)
            .map_err(|_| Error::new(sys::NEUG_E_PARAMETERS, "the query has a NUL in it"))?;
        let params = params.map(|p| CString::new(p).expect("JSON of parameters has no NUL"));
        let mut out = ptr::null_mut();
        let mut err = ptr::null_mut();
        let status = unsafe {
            sys::neug_conn_query(
                self.ptr,
                cypher.as_ptr(),
                access.raw(),
                params.as_ref().map_or(ptr::null(), |p| p.as_ptr()),
                &mut out,
                &mut err,
            )
        };
        check(status, err)?;
        Ok(QueryResult::new(out))
    }

    /// Starts a transaction, which is rolled back unless it is committed.
    pub fn begin(&mut self, mode: TxMode) -> Result<Transaction<'_>> {
        let mut err = ptr::null_mut();
        let status =
            unsafe { sys::neug_conn_begin(self.ptr, (mode == TxMode::ReadOnly).into(), &mut err) };
        check(status, err)?;
        Ok(Transaction {
            conn: self,
            finished: false,
        })
    }

    pub fn in_transaction(&self) -> bool {
        unsafe { sys::neug_conn_in_transaction(self.ptr) != 0 }
    }
}

/// A transaction. Dropping it without `commit` rolls it back.
pub struct Transaction<'c> {
    conn: &'c mut Connection,
    finished: bool,
}

impl Transaction<'_> {
    pub fn query(&mut self, cypher: &str) -> Result<QueryResult> {
        self.conn.query(cypher)
    }

    pub fn query_with(
        &mut self,
        cypher: &str,
        access: Access,
        params: &Params,
    ) -> Result<QueryResult> {
        self.conn.query_with(cypher, access, params)
    }

    pub fn commit(mut self) -> Result<()> {
        self.finished = true;
        let mut err = ptr::null_mut();
        let status = unsafe { sys::neug_conn_commit(self.conn.ptr, &mut err) };
        check(status, err)
    }

    pub fn rollback(mut self) -> Result<()> {
        self.finished = true;
        let mut err = ptr::null_mut();
        let status = unsafe { sys::neug_conn_rollback(self.conn.ptr, &mut err) };
        check(status, err)
    }
}

impl Drop for Transaction<'_> {
    fn drop(&mut self) {
        if !self.finished {
            let mut err = ptr::null_mut();
            let status = unsafe { sys::neug_conn_rollback(self.conn.ptr, &mut err) };
            if status != sys::NEUG_OK && !err.is_null() {
                unsafe { sys::neug_error_free(err) };
            }
        }
    }
}

/// The type of a column.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum ColumnType {
    Int32,
    UInt32,
    Int64,
    UInt64,
    Float,
    Double,
    String,
    Bool,
    /// Read as `i64` (the raw value of the engine) or as a `String`.
    Timestamp,
    /// Read as `i64` or as a `String`.
    Date,
    /// Read as a `String`.
    Interval,
    /// Read as a `String`.
    List,
    /// Read as a `String`.
    Struct,
    /// Read as a `String`.
    Vertex,
    /// Read as a `String`.
    Edge,
    /// Read as a `String`.
    Path,
    Unknown,
}

impl ColumnType {
    fn from_raw(raw: sys::neug_type) -> Self {
        match raw {
            sys::NEUG_T_INT32 => ColumnType::Int32,
            sys::NEUG_T_UINT32 => ColumnType::UInt32,
            sys::NEUG_T_INT64 => ColumnType::Int64,
            sys::NEUG_T_UINT64 => ColumnType::UInt64,
            sys::NEUG_T_FLOAT => ColumnType::Float,
            sys::NEUG_T_DOUBLE => ColumnType::Double,
            sys::NEUG_T_STRING => ColumnType::String,
            sys::NEUG_T_BOOL => ColumnType::Bool,
            sys::NEUG_T_TIMESTAMP => ColumnType::Timestamp,
            sys::NEUG_T_DATE => ColumnType::Date,
            sys::NEUG_T_INTERVAL => ColumnType::Interval,
            sys::NEUG_T_LIST => ColumnType::List,
            sys::NEUG_T_STRUCT => ColumnType::Struct,
            sys::NEUG_T_VERTEX => ColumnType::Vertex,
            sys::NEUG_T_EDGE => ColumnType::Edge,
            sys::NEUG_T_PATH => ColumnType::Path,
            _ => ColumnType::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    pub name: String,
    pub ty: ColumnType,
}

/// The answer to a query. It owns its data and may outlive its connection.
pub struct QueryResult {
    ptr: *mut sys::neug_result,
    columns: Vec<Column>,
}

unsafe impl Send for QueryResult {}

impl Drop for QueryResult {
    fn drop(&mut self) {
        unsafe { sys::neug_result_free(self.ptr) }
    }
}

impl QueryResult {
    fn new(ptr: *mut sys::neug_result) -> Self {
        let count = unsafe { sys::neug_result_columns(ptr) };
        let columns = (0..count)
            .map(|i| unsafe {
                Column {
                    name: CStr::from_ptr(sys::neug_result_column_name(ptr, i))
                        .to_string_lossy()
                        .into_owned(),
                    ty: ColumnType::from_raw(sys::neug_result_column_type(ptr, i)),
                }
            })
            .collect();
        QueryResult { ptr, columns }
    }

    /// The number of rows.
    pub fn len(&self) -> usize {
        unsafe { sys::neug_result_rows(self.ptr) }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    /// The rows, from the first. A row is read before the next is asked for:
    /// `while let Some(row) = rows.next() { ... }`.
    pub fn rows(&mut self) -> Rows<'_> {
        unsafe { sys::neug_result_rewind(self.ptr) };
        Rows { result: self }
    }
}

/// The cursor over the rows of a result.
pub struct Rows<'a> {
    result: &'a mut QueryResult,
}

impl Rows<'_> {
    // Not the Iterator trait: a row borrows the cursor, so the next cannot be asked for before
    // it is dropped.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<Row<'_>> {
        if unsafe { sys::neug_result_step(self.result.ptr) } != 0 {
            Some(Row {
                result: &*self.result,
            })
        } else {
            None
        }
    }
}

/// One row of a result.
pub struct Row<'r> {
    result: &'r QueryResult,
}

impl Row<'_> {
    /// A cell, as the type it has (or one the engine widens it to: a `u32` as an `i64`). A NULL
    /// is an error for a plain type and `None` for an `Option`.
    pub fn get<T: FromCell>(&self, column: usize) -> Result<T> {
        // The row borrows the live result and cannot advance its cursor.
        unsafe { T::from_cell(self.result.ptr, column) }
    }

    /// The same by the name of the column, as the result lists it or without the number of the
    /// variable the engine puts in front (`c.name` for `_7_c.name`).
    pub fn get_by_name<T: FromCell>(&self, name: &str) -> Result<T> {
        let strip = |s: &str| -> String {
            match s.strip_prefix('_').and_then(|r| r.split_once('_')) {
                Some((digits, rest))
                    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) =>
                {
                    rest.to_owned()
                }
                _ => s.to_owned(),
            }
        };
        let index = self
            .result
            .columns
            .iter()
            .position(|c| c.name == name)
            .or_else(|| {
                self.result
                    .columns
                    .iter()
                    .position(|c| strip(&c.name) == name)
            })
            .ok_or_else(|| Error::new(sys::NEUG_E_COLUMN, format!("no column named {name}")))?;
        self.get(index)
    }

    pub fn is_null(&self, column: usize) -> Result<bool> {
        let mut out = 0;
        let mut err = ptr::null_mut();
        let status =
            unsafe { sys::neug_result_is_null(self.result.ptr, column, &mut out, &mut err) };
        check(status, err)?;
        Ok(out != 0)
    }
}

/// A type a cell can be read as.
pub trait FromCell: Sized {
    /// Read from the current row of a native result.
    ///
    /// # Safety
    /// `result` must be a live NeuG result positioned on a row, and its cursor
    /// must not be advanced or the result freed during this call.
    ///
    /// ```compile_fail
    /// let _ = <i64 as neug::FromCell>::from_cell(std::ptr::null_mut(), 0);
    /// ```
    unsafe fn from_cell(result: *mut sys::neug_result, column: usize) -> Result<Self>;
}

fn null_error() -> Error {
    Error::new(sys::NEUG_NULL, "the cell is NULL: read it as an Option")
}

macro_rules! scalar {
    ($ty:ty, $function:ident, $zero:expr) => {
        impl FromCell for $ty {
            unsafe fn from_cell(result: *mut sys::neug_result, column: usize) -> Result<Self> {
                let mut out = $zero;
                let mut err = ptr::null_mut();
                let status = unsafe { sys::$function(result, column, &mut out, &mut err) };
                match status {
                    sys::NEUG_OK => Ok(out),
                    sys::NEUG_NULL => Err(null_error()),
                    _ => Err(unsafe { Error::take(err, status) }),
                }
            }
        }
    };
}

scalar!(i32, neug_result_get_i32, 0i32);
scalar!(u32, neug_result_get_u32, 0u32);
scalar!(i64, neug_result_get_i64, 0i64);
scalar!(u64, neug_result_get_u64, 0u64);
scalar!(f32, neug_result_get_f32, 0f32);
scalar!(f64, neug_result_get_f64, 0f64);

impl FromCell for bool {
    unsafe fn from_cell(result: *mut sys::neug_result, column: usize) -> Result<Self> {
        let mut out = 0u8;
        let mut err = ptr::null_mut();
        let status = unsafe { sys::neug_result_get_bool(result, column, &mut out, &mut err) };
        match status {
            sys::NEUG_OK => Ok(out != 0),
            sys::NEUG_NULL => Err(null_error()),
            _ => Err(unsafe { Error::take(err, status) }),
        }
    }
}

impl FromCell for String {
    unsafe fn from_cell(result: *mut sys::neug_result, column: usize) -> Result<Self> {
        let mut text: *const c_char = ptr::null();
        let mut len = 0usize;
        let mut err = ptr::null_mut();
        let status =
            unsafe { sys::neug_result_get_string(result, column, &mut text, &mut len, &mut err) };
        match status {
            sys::NEUG_OK => {
                // the text belongs to the result until the next call: it is copied
                let bytes = unsafe { std::slice::from_raw_parts(text.cast::<u8>(), len) };
                String::from_utf8(bytes.to_vec())
                    .map_err(|_| Error::new(sys::NEUG_E_OTHER, "the text is not UTF-8"))
            }
            sys::NEUG_NULL => Err(null_error()),
            _ => Err(unsafe { Error::take(err, status) }),
        }
    }
}

impl<T: FromCell> FromCell for Option<T> {
    unsafe fn from_cell(result: *mut sys::neug_result, column: usize) -> Result<Self> {
        match unsafe { T::from_cell(result, column) } {
            Ok(value) => Ok(Some(value)),
            Err(e) if e.code() == sys::NEUG_NULL => Ok(None),
            Err(e) => Err(e),
        }
    }
}
