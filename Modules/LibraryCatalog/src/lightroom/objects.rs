use super::*;
use std::collections::HashSet;
fn tidy_path(s: &str) -> Option<String> {
    let mut out = Vec::new();
    for part in s.trim_matches('/').split('/') {
        match part {
            "" | "." => (),
            ".." => return None,
            s if s.contains('\0') => return None,
            s => out.push(s),
        }
    }
    Some(out.join("/"))
}
fn folder_ref(_ctx: &Context<'_>, r: &Value) -> Option<(i64, String)> {
    Some((
        integer(&r["rootFolder"])?,
        tidy_path(r["pathFromRoot"].as_str().unwrap_or(""))?,
    ))
}
fn folder_id(ctx: &Context<'_>, vol: i64, path: &str) -> Result<String> {
    let with_slash = format!("{path}/");
    let source_id:Option<i64>=ctx.source.query_row("SELECT id_local FROM AgLibraryFolder WHERE rootFolder=?1 AND (pathFromRoot=?2 OR pathFromRoot=?3) ORDER BY id_local LIMIT 1",params![vol,path,with_slash],|r|r.get(0)).optional()?;
    Ok(match source_id {
        Some(id) => ctx.id("folder", id)?,
        None => ctx.named("folderPath", &format!("{vol}/{path}")),
    })
}
fn volume(ctx: &Context<'_>, id: i64, row: &Value, item: &mut Item) -> Result<()> {
    let key = ctx.id("volume", id)?;
    let path = row["absolutePath"].as_str().unwrap_or("");
    item.org("volume",&id.to_string(),&key,json!({"action":"org.saveVolume","volumeID":key,"name":row["name"].as_str().filter(|s|!s.is_empty()).unwrap_or(path),"locator":path,"online":Path::new(path).is_absolute()&&Path::new(path).is_dir()}));
    Ok(())
}
fn folder(ctx: &Context<'_>, id: i64, row: &Value, item: &mut Item) -> Result<()> {
    let Some((vol, path)) = folder_ref(ctx, row) else {
        item.report(
            "organization",
            "folder",
            "missing",
            "Invalid volume or relative path",
            Value::Null,
        );
        return Ok(());
    };
    let Some(root) = source::record(&ctx.source, "AgLibraryRootFolder", vol)? else {
        item.report(
            "organization",
            "volume",
            "missing",
            "Folder refers to an absent volume",
            json!(vol),
        );
        return Ok(());
    };
    let pieces = path
        .split('/')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>();
    let mut parent = None::<String>;
    // Some Lightroom catalogs have no parentId values. Rebuild intermediate folders from pathFromRoot.
    for n in 0..=pieces.len() {
        let here = pieces[..n].join("/");
        let folder = if n == pieces.len() {
            ctx.id("folder", id)?
        } else {
            folder_id(ctx, vol, &here)?
        };
        let source_key = if n == pieces.len() {
            id.to_string()
        } else {
            ctx.source.query_row("SELECT id_local FROM AgLibraryFolder WHERE rootFolder=?1 AND (pathFromRoot=?2 OR pathFromRoot=?3) ORDER BY id_local LIMIT 1",params![vol,here,format!("{here}/")],|r|r.get::<_,i64>(0)).optional()?.map(|v|v.to_string()).unwrap_or_else(||format!("path:{vol}/{here}"))
        };
        let name = if n == 0 {
            root["name"]
                .as_str()
                .filter(|s| !s.is_empty())
                .unwrap_or("Lightroom")
        } else {
            pieces[n - 1]
        };
        item.org("folder",&source_key,&folder,json!({"action":"org.saveFolder","folderID":folder,"volumeID":ctx.id("volume",vol)?,"parentID":parent,"name":name}));
        parent = Some(folder);
    }
    Ok(())
}
struct LocalFile {
    folder: i64,
    name: String,
    path: PathBuf,
    root: PathBuf,
    ext: String,
}
fn file(ctx: &Context<'_>, r: &Value) -> Result<Option<LocalFile>> {
    let Some(id) = integer(&r["folder"]) else {
        return Ok(None);
    };
    let Some(folder) = source::record(&ctx.source, "AgLibraryFolder", id)? else {
        return Ok(None);
    };
    let Some((vid, rel)) = folder_ref(ctx, &folder) else {
        return Ok(None);
    };
    let Some(root) = source::record(&ctx.source, "AgLibraryRootFolder", vid)? else {
        return Ok(None);
    };
    let base = r["baseName"].as_str().unwrap_or("");
    let ext = r["extension"].as_str().unwrap_or("");
    if base.is_empty()
        || base.contains(['/', '\\', '\0'])
        || ext.contains(['/', '\\', '\0'])
        || base == ".."
        || base == "."
    {
        return Ok(None);
    }
    let name = if ext.is_empty() {
        base.to_string()
    } else {
        format!("{base}.{ext}")
    };
    let root = PathBuf::from(root["absolutePath"].as_str().unwrap_or(""));
    Ok(Some(LocalFile {
        folder: id,
        path: root.join(rel).join(&name),
        root,
        name,
        ext: ext.into(),
    }))
}
fn sides(ctx: &Context<'_>, id: i64, r: &Value, file: &LocalFile, item: &mut Item) -> Result<()> {
    let claimed = r["sidecarExtensions"].as_str().unwrap_or("").to_lowercase();
    for ext in ["xmp", "acr"] {
        let included = claimed
            .split(|c: char| !c.is_ascii_alphanumeric())
            .any(|v| v == ext);
        let key = format!("sidecar:{ext}");
        if !ctx.sidecars {
            if included {
                item.report(
                    "appearance",
                    &key,
                    "skipped",
                    "Reading adjacent XMP/ACR files was not selected",
                    json!(id),
                );
            }
            continue;
        }
        if !file.root.is_absolute() {
            if included {
                item.report(
                    "appearance",
                    &key,
                    "missing",
                    "Original volume is unavailable on this platform",
                    json!(id),
                );
            }
            continue;
        }
        let Some(root) = file.root.canonicalize().ok() else {
            if included {
                item.report(
                    "appearance",
                    &key,
                    "missing",
                    "Original volume is unavailable",
                    json!(id),
                );
            }
            continue;
        };
        let mut paths = vec![
            file.path.with_extension(ext),
            file.path.with_extension(ext.to_ascii_uppercase()),
        ];
        paths.dedup();
        let mut seen = HashSet::new();
        let mut found = false;
        for p in paths {
            let Some(sig) = source::file_stamp(&p).ok().flatten() else {
                continue;
            };
            let real = p.canonicalize()?;
            if !real.starts_with(&root) || !seen.insert((sig.device, sig.inode)) {
                continue;
            }
            let resource = source::content(ctx.catalog, &p, "sidecar")?;
            if source::file_stamp(&p)?.as_ref() != Some(&sig) {
                item.report(
                    "appearance",
                    &key,
                    "uncertain",
                    "Adjacent sidecar changed while being read",
                    Value::Null,
                );
                continue;
            }
            item.link(
                &key,
                p.file_name().and_then(|s| s.to_str()).unwrap_or(ext),
                resource,
            );
            found = true;
        }
        if found {
            item.report("appearance",&key,"archivedOnly","Original sidecar bytes captured independently; catalog revision binding is unknown",Value::Null);
        } else if included {
            item.report(
                "appearance",
                &key,
                "missing",
                "A sidecar referenced by Lightroom is unavailable",
                Value::Null,
            );
        }
    }
    Ok(())
}
fn file_item(ctx: &Context<'_>, id: i64, r: &Value, item: &mut Item) -> Result<()> {
    let Some(file) = file(ctx, r)? else {
        item.report(
            "organization",
            "file",
            "missing",
            "Original file has an incomplete source path",
            Value::Null,
        );
        return Ok(());
    };
    let extra = if source::exists(&ctx.source, "AgLibraryFileAssetMetadata")? {
        ctx.source.query_row("SELECT CASE WHEN typeof(sha256)='blob' AND length(sha256)=32 THEN lower(hex(sha256)) ELSE CAST(sha256 AS TEXT) END,fileSize FROM AgLibraryFileAssetMetadata WHERE fileId IN(?1,?2) LIMIT 1",params![id,r["id_global"].as_str()],|r|Ok(json!({"sha256":source::value(r,0)?,"size":source::value(r,1)?}))).optional()?
    } else {
        None
    };
    let md5 = if r["md5"].is_object() {
        ctx.source.query_row("SELECT CASE WHEN typeof(md5)='blob' AND length(md5)=16 THEN lower(hex(md5)) END FROM AgLibraryFile WHERE id_local=?",[id],|r|r.get::<_,Option<String>>(0))?
    } else {
        r["md5"].as_str().map(str::to_owned)
    };
    let hash = json!({"md5":md5,"original":extra});
    item.file = Some(
        json!({"fileID":ctx.id("file",id)?,"folderID":ctx.id("folder",file.folder)?,"path":file.path,"type":file.ext,"checksums":hash}),
    );
    item.report(
        "organization",
        "original",
        "mapped",
        "Source locator recorded; this occurrence awaits content verification",
        json!({"filename":file.name,"checksums":hash}),
    );
    sides(ctx, id, r, &file, item)
}
fn develop(ctx: &Context<'_>, id: i64, item: &mut Item) -> Result<Option<String>> {
    if !source::exists(&ctx.source, "Adobe_imageDevelopSettings")? {
        return Ok(None);
    }
    let mut q=ctx.source.prepare_cached("SELECT id_local,CAST(digest AS TEXT),CAST(text AS BLOB) FROM Adobe_imageDevelopSettings WHERE image=?1 ORDER BY id_local")?;
    let rows = q.query_map([id], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, Option<String>>(1)?,
            r.get::<_, Option<Vec<u8>>>(2)?,
        ))
    })?;
    let mut digests = HashSet::new();
    let mut loaded = false;
    for row in rows {
        let (key, digest, packet) = row?;
        if let Some(d) = digest {
            digests.insert(d);
        }
        if let Some(p) = packet.filter(|p| !p.is_empty()) {
            let resource = source::bytes(ctx.catalog, &p, "adobePayload")?;
            item.link(
                &format!("develop:{key}"),
                "Adobe_imageDevelopSettings.text",
                resource,
            );
            loaded = true;
        }
    }
    item.report(
        "appearance",
        "adobeDevelop",
        if loaded { "archivedOnly" } else { "missing" },
        if loaded {
            "Exact proprietary payload retained"
        } else {
            "No per-image develop payload"
        },
        Value::Null,
    );
    Ok(if digests.len() == 1 {
        digests.into_iter().next()
    } else {
        None
    })
}
fn image_item(ctx: &Context<'_>, id: i64, r: &Value, item: &mut Item) -> Result<()> {
    let work = ctx.id("image", id)?;
    let original = integer(&r["rootFile"]);
    let raw = match original {
        Some(f) => source::record(&ctx.source, "AgLibraryFile", f)?,
        None => None,
    };
    let found = match raw.as_ref() {
        Some(f) => file(ctx, f)?,
        None => None,
    };
    let master = integer(&r["masterImage"]).filter(|n| *n != 0);
    let master_exists = match master {
        Some(k) => ctx.source.query_row(
            "SELECT EXISTS(SELECT 1 FROM Adobe_images WHERE id_local=?1)",
            [k],
            |r| r.get::<_, bool>(0),
        )?,
        None => true,
    };
    // Materialize masters before independent copies, regardless of their source row order.
    let role = if master.is_some() && master_exists {
        "virtual"
    } else {
        "offline"
    };
    if !master_exists {
        item.report(
            "organization",
            "master",
            "missing",
            "Virtual copy references an absent master",
            json!(master),
        );
    }
    if found.is_none() {
        item.report(
            "organization",
            "fileReference",
            "missing",
            "No complete physical-file reference for this work",
            json!(original),
        );
    }
    let mut meta = metadata::image(ctx, id, r, &work, item)?;
    meta["sourceFileID"] = json!(original.map(|v| ctx.id("file", v)).transpose()?);
    meta["sourceImageID"] = json!(id);
    meta["sourceCatalogID"] = json!(ctx.source_id);
    meta["sourceFilePath"] = json!(found.as_ref().map(|v| &v.path));
    meta["originalState"] = json!("unverified");
    let digest = develop(ctx, id, item)?;
    let look = preview::get(ctx, id, digest.as_deref())?;
    let appearance = json!({"origin":"lightroom","resourceID":look.resource.as_ref().map(|r|&r.resource_id),"revisionBound":look.revision_bound,"state":look.state,"width":look.width,"height":look.height,"sourceCatalogID":ctx.source_id,"sourceImageID":id,"developDigest":digest});
    let appearance_key = hash(&appearance)?;
    if let Some(res) = look.resource.clone() {
        item.link(
            "historicalLook",
            "ImageCacheEntry.imageId / Pyramid.uuid,digest",
            res,
        );
    }
    item.report(
        "appearance",
        "preview",
        if look.revision_bound {
            "mapped"
        } else if look.decoded {
            "uncertain"
        } else {
            "missing"
        },
        &look.state,
        appearance.clone(),
    );
    item.look = Some((work.clone(), look));
    let name = r["copyName"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| found.as_ref().map(|f| f.name.as_str()))
        .unwrap_or("Lightroom");
    let cmd = json!({"action":"org.saveWork","workID":work,"kind":role,"masterWorkID":master.filter(|_|master_exists).map(|i|ctx.id("image",i)).transpose()?,"name":name,"folderID":found.as_ref().filter(|_|role!="virtual").map(|f|ctx.id("folder",f.folder)).transpose()?,"metadata":meta,"rating":integer(&r["rating"]),"appearance":appearance,"versionID":ctx.named("version",&format!("{id}:{appearance_key}"))});
    item.org("image", &id.to_string(), &work, cmd);
    item.report(
        "organization",
        "work",
        "mapped",
        if master.is_some() {
            "Independent virtual copy and version"
        } else {
            "Original work and source-file placeholder"
        },
        json!({"master":master,"file":original}),
    );
    Ok(())
}
fn collection(ctx: &Context<'_>, id: i64, item: &mut Item) -> Result<()> {
    fn plan(ctx: &Context<'_>, id: i64, item: &mut Item, seen: &mut HashSet<i64>) -> Result<bool> {
        if seen.len() > 128 || !seen.insert(id) {
            return Ok(false);
        }
        let Some(r) = source::record(&ctx.source, "AgLibraryCollection", id)? else {
            return Ok(false);
        };
        let parent = integer(&r["parent"]).filter(|v| *v > 0);
        let parent = if let Some(p) = parent {
            if plan(ctx, p, item, seen)? {
                Some(ctx.id("collection", p)?)
            } else {
                item.report(
                    "organization",
                    "parent",
                    "missing",
                    "Unavailable or cyclic collection parent",
                    json!(p),
                );
                None
            }
        } else {
            None
        };
        let raw = r["creationId"].as_str().unwrap_or("");
        let mut predicate = None;
        let mut source_rule = None;
        let kind = match raw {
            "com.adobe.ag.library.collection" => "regular",
            "com.adobe.ag.library.group" => "group",
            "com.adobe.ag.library.smart_collection" => {
                if let Some((s, pred)) = order::rule(&ctx.source, id)? {
                    source_rule = Some(s);
                    predicate = pred;
                }
                if predicate.is_some() {
                    "smart"
                } else {
                    "regular"
                }
            }
            _ => {
                item.report(
                    "organization",
                    "collectionType",
                    "unsupported",
                    "Adobe module object preserved in the source container",
                    json!(raw),
                );
                return Ok(false);
            }
        };
        let target = ctx.id("collection", id)?;
        let mut cmd = json!({"action":"org.saveCollection","collectionID":target,"name":r["name"].as_str().unwrap_or("Lightroom"),"kind":kind,"parentID":parent});
        if let Some(p) = predicate.as_ref() {
            cmd["rule"] = json!({"predicate":p});
        }
        if raw.ends_with("smart_collection") && item.key == id.to_string() {
            item.report(
                "organization",
                "smartRule",
                if predicate.is_some() {
                    "mapped"
                } else {
                    "archivedOnly"
                },
                if predicate.is_some() {
                    "Rating rule can be reevaluated"
                } else {
                    "Original rule preserved; only available source memberships can be shown"
                },
                json!({"raw":source_rule,"predicate":predicate}),
            );
        }
        item.org("collection", &id.to_string(), &target, cmd);
        Ok(true)
    }
    if plan(ctx, id, item, &mut HashSet::new())? {
        item.report(
            "organization",
            "collection",
            "mapped",
            "Collection hierarchy preserved",
            Value::Null,
        );
    }
    Ok(())
}
fn stack(ctx: &Context<'_>, table: &str, id: i64, r: &Value, item: &mut Item) -> Result<()> {
    let folder = table == "AgLibraryFolderStack";
    let members = if folder {
        "AgLibraryFolderStackImage"
    } else {
        "AgLibraryCollectionStackImage"
    };
    if !source::exists(&ctx.source, members)? {
        item.report(
            "organization",
            "members",
            "missing",
            "Stack membership table unavailable",
            Value::Null,
        );
        return Ok(());
    }
    let mut q=ctx.source.prepare(&format!("SELECT m.image,f.folder FROM {members} m LEFT JOIN Adobe_images i ON i.id_local=m.image LEFT JOIN AgLibraryFile f ON f.id_local=i.rootFile WHERE m.stack=?1 ORDER BY m.position,m.id_local"))?;
    let mut works = Vec::new();
    let mut folders = HashSet::new();
    for v in q.query_map([id], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, Option<i64>>(1)?))
    })? {
        let (i, f) = v?;
        works.push(ctx.id("image", i)?);
        if let Some(f) = f {
            folders.insert(f);
        }
    }
    let scope = if folder {
        if folders.len() == 1 {
            folders
                .into_iter()
                .next()
                .map(|v| ctx.id("folder", v))
                .transpose()?
        } else {
            None
        }
    } else {
        integer(&r["collection"])
            .map(|v| ctx.id("collection", v))
            .transpose()?
    };
    let Some(scope) = scope.filter(|_| !works.is_empty()) else {
        item.report(
            "organization",
            "scope",
            "missing",
            "Stack has no single source scope or members",
            Value::Null,
        );
        return Ok(());
    };
    let parent_table = if folder {
        "AgLibraryFolderStackData"
    } else {
        "AgLibraryCollectionStackData"
    };
    let cover = if source::exists(&ctx.source, parent_table)? {
        ctx.source
            .query_row(
                &format!("SELECT stackParent FROM {parent_table} WHERE stack=?1 LIMIT 1"),
                [id],
                |r| r.get::<_, Option<i64>>(0),
            )
            .optional()?
            .flatten()
            .map(|i| ctx.id("image", i))
            .transpose()?
            .filter(|w| works.contains(w))
    } else {
        None
    };
    let cover = cover.unwrap_or_else(|| works[0].clone());
    let target = ctx.id(table, id)?;
    item.org(table,&id.to_string(),&target,json!({"action":"org.saveStack","stackID":target,"scopeKind":if folder{"folder"}else{"collection"},"scopeID":scope,"workIDs":works,"coverWorkID":cover,"collapsed":integer(&r["collapsed"])==Some(1)}));
    item.report(
        "organization",
        "stack",
        "mapped",
        "Scoped stack includes cover and source member order",
        json!({"scopeID":scope,"coverWorkID":cover,"count":works.len()}),
    );
    Ok(())
}
pub(super) fn prepare(ctx: &Context<'_>, table: &str, id: i64) -> Result<Item> {
    let r = source::record(&ctx.source, table, id)?.ok_or("Missing snapshot row")?;
    let mut item = Item::new(table, &id.to_string());
    match table {
        "AgLibraryRootFolder" => {
            volume(ctx, id, &r, &mut item)?;
            item.report(
                "organization",
                "volume",
                "mapped",
                "Source volume recorded",
                Value::Null,
            );
        }
        "AgLibraryFolder" => {
            folder(ctx, id, &r, &mut item)?;
            if !item.org.is_empty() {
                item.report(
                    "organization",
                    "folder",
                    "mapped",
                    "Folder hierarchy recorded",
                    Value::Null,
                );
            }
        }
        "AgLibraryFile" => file_item(ctx, id, &r, &mut item)?,
        "Adobe_images" => image_item(ctx, id, &r, &mut item)?,
        "AgLibraryCollection" => collection(ctx, id, &mut item)?,
        "AgLibraryFolderStack" | "AgLibraryCollectionStack" => {
            stack(ctx, table, id, &r, &mut item)?
        }
        _ => return Err("Unknown Lightroom source object type".into()),
    }
    Ok(item)
}
