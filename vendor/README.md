anydoc 0.2.4, upstream 42bf1c5ecdde9eb0d96d6bd75a9e6698cf93b14c
https://github.com/firecrawl/anydoc — MIT (vendor/anydoc/LICENSE)
Local changes: remove binding workspace/dev dependencies, expose render_document
for resolved local asset references, tighten resource limits for desktop usage.
No hosted OCR, Node.js, Python runtime or network calls. PDF conversion disabled.
Build: cargo build --locked --release --manifest-path vendor/file-actions/Cargo.toml
PDF Markdown adapter disabled and pdf-inspector dependency removed entirely.
