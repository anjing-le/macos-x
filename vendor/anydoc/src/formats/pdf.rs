//! macos-x intentionally excludes PDF-to-Markdown after failed quality validation.
use crate::error::ConvertError;
pub fn to_markdown(_bytes: &[u8]) -> Result<String, ConvertError> {
    Err(ConvertError::Unsupported("PDF-to-Markdown is not available".into()))
}
