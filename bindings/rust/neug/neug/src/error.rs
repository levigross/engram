use std::ffi::CStr;
use std::fmt;

use neug_sys as sys;

/// What went wrong. `code` is the code of NeuG (from 1001) or of the C interface (from 10001);
/// `message` is the text the engine gives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    code: i32,
    message: String,
}

/// The kind of an error, for a program that has to tell them apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[non_exhaustive]
pub enum ErrorKind {
    /// The engine refused with a code of its own: a wrong query (5001).
    Engine,
    /// A cell was read as a type it does not have.
    Type,
    /// A cell is NULL and was read as a plain value: read an `Option`.
    Null,
    /// There is no such column.
    Column,
    /// The cursor is not on a row.
    NoRow,
    /// The parameters are not a JSON object, or a text has a NUL in it.
    Parameters,
    /// The library is not of the version of these bindings.
    Abi,
    /// The engine threw: a second connection to a database that is read and written, an
    /// extension that is not there. The text ends with the code of NeuG (`Error Code: 4001`).
    Exception,
    Other,
}

impl Error {
    pub(crate) fn new(code: i32, message: impl Into<String>) -> Self {
        Error {
            code,
            message: message.into(),
        }
    }

    /// Reads the error that the C interface made, and frees it.
    ///
    /// # Safety
    /// `err` is null or a `neug_error` that nothing else frees.
    pub(crate) unsafe fn take(err: *mut sys::neug_error, status: i32) -> Self {
        if err.is_null() {
            return Error::new(status, "(the library gave no message)");
        }
        let code = sys::neug_error_code(err);
        let message = CStr::from_ptr(sys::neug_error_message(err))
            .to_string_lossy()
            .into_owned();
        sys::neug_error_free(err);
        Error { code, message }
    }

    pub fn code(&self) -> i32 {
        self.code
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    pub fn kind(&self) -> ErrorKind {
        match self.code {
            sys::NEUG_NULL => ErrorKind::Null,
            sys::NEUG_E_TYPE => ErrorKind::Type,
            sys::NEUG_E_COLUMN => ErrorKind::Column,
            sys::NEUG_E_NO_ROW => ErrorKind::NoRow,
            sys::NEUG_E_PARAMETERS | sys::NEUG_E_NULL_ARGUMENT => ErrorKind::Parameters,
            sys::NEUG_E_ABI => ErrorKind::Abi,
            sys::NEUG_E_EXCEPTION => ErrorKind::Exception,
            code if code >= 10000 => ErrorKind::Other,
            _ => ErrorKind::Engine,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "NeuG error {}: {}", self.code, self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// Turns the status of a call and the error it may have made into a result.
pub(crate) fn check(status: i32, err: *mut sys::neug_error) -> Result<()> {
    if status == sys::NEUG_OK {
        Ok(())
    } else {
        Err(unsafe { Error::take(err, status) })
    }
}
