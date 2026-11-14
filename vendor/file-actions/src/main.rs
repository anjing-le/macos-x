use anydoc::model::{Block, CellSlot, ImageSource, Inline, inlines_to_plain_text};
use std::{fs, path::Path};
fn inline_assets(items: &mut [Inline], paths: &std::collections::HashMap<usize, String>) {
    for i in items {
        match i {
            Inline::Image { source, .. } => {
                if let ImageSource::Asset(id) = source {
                    if let Some(path) = paths.get(&id.0) {
                        *source = ImageSource::External(path.clone());
                    }
                }
            }
            Inline::Link { content, .. } => inline_assets(content, paths),
            _ => {}
        }
    }
}
fn blocks(
    items: &mut [Block],
    plain: &mut String,
    paths: &std::collections::HashMap<usize, String>,
) {
    for b in items {
        match b {
            Block::Heading { content, .. } | Block::Paragraph(content) => {
                plain.push_str(&inlines_to_plain_text(content));
                plain.push('\n');
                inline_assets(content, paths);
            }
            Block::List(list) => {
                for item in &mut list.items {
                    blocks(&mut item.blocks, plain, paths)
                }
            }
            Block::BlockQuote(b) => blocks(b, plain, paths),
            Block::Table(t) => {
                for row in &mut t.grid {
                    for cell in row {
                        if let CellSlot::Origin(c) = cell {
                            blocks(&mut c.blocks, plain, paths);
                            plain.push('\t');
                        }
                    }
                    plain.push('\n');
                }
            }
            Block::CodeBlock { text, .. } | Block::Math(text) => {
                plain.push_str(text);
                plain.push('\n');
            }
            Block::Rule => plain.push('\n'),
        }
    }
}
fn convert(input: &Path, output: &Path, mode: &str) -> Result<(), Box<dyn std::error::Error>> {
    let meta = fs::metadata(input)?;
    if !meta.is_file() || meta.len() > 16 * 1024 * 1024 {
        return Err("input_limit".into());
    }
    let bytes = fs::read(input)?;
    let format = anydoc::Format::from_bytes(&bytes)
        .or_else(|| anydoc::Format::from_path(input))
        .ok_or("unsupported")?;
    if format == anydoc::Format::Pdf {
        return Err("unsupported".into());
    }
    let mut doc = anydoc::to_document(&bytes, format)?;
    let paths: std::collections::HashMap<usize, String> = doc
        .assets
        .iter()
        .filter_map(|a| {
            let ext = match a.media_type.as_str() {
                "image/png" => "png",
                "image/jpeg" => "jpg",
                "image/gif" => "gif",
                "image/webp" => "webp",
                _ => return None,
            };
            Some((a.id.0, format!("assets/image-{}.{}", a.id.0, ext)))
        })
        .collect();
    let mut plain = String::new();
    blocks(&mut doc.blocks, &mut plain, &paths);
    for note in &mut doc.notes {
        plain.push_str(&note.id);
        plain.push(':');
        blocks(&mut note.blocks, &mut plain, &paths)
    }
    fs::create_dir_all(output)?;
    if mode == "text" {
        if plain.len() > 8 * 1024 * 1024 {
            return Err("output_limit".into());
        }
        fs::write(output.join("result.txt"), plain)?;
    } else {
        let md = anydoc::render_document(&doc);
        let assets = output.join("assets");
        for asset in &doc.assets {
            // Only known raster media are exported; never emit executable embedded objects.
            let ext = match asset.media_type.as_str() {
                "image/png" => "png",
                "image/jpeg" => "jpg",
                "image/gif" => "gif",
                "image/webp" => "webp",
                _ => continue,
            };
            if !asset.bytes.is_empty() {
                fs::create_dir_all(&assets)?;
                fs::write(
                    assets.join(format!("image-{}.{}", asset.id.0, ext)),
                    &asset.bytes,
                )?;
            }
        }
        // Missing or unsupported assets must not be advertised as preserved.
        for asset in &doc.assets {
            if !["image/png", "image/jpeg", "image/gif", "image/webp"]
                .contains(&asset.media_type.as_str())
            {
                return Err("unsupported_asset".into());
            }
        }
        if md.len() > 8 * 1024 * 1024 {
            return Err("output_limit".into());
        }
        fs::write(output.join("result.md"), md)?;
    }
    Ok(())
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 4 || !["markdown", "text"].contains(&a[3].as_str()) {
        std::process::exit(2)
    }
    if let Err(error) = convert(Path::new(&a[1]), Path::new(&a[2]), &a[3]) {
        // Stable category only: never put file contents/paths in application diagnostics.
        let text = error.to_string();
        let category = if text.contains("unsupported_asset") {
            "asset"
        } else if text.contains("resource limit") || text.contains("limit") {
            "limit"
        } else if text.contains("encrypted") || text.contains("password") {
            "encrypted"
        } else if text.contains("unsupported") {
            "unsupported"
        } else {
            "invalid"
        };
        eprintln!("{category}");
        std::process::exit(1)
    }
}
