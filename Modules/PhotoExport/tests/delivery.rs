use base64::{engine::general_purpose::STANDARD, Engine};
use rawmaster_photo_export::{
    encode, geometry, normalize_preset, ordered_selection, output_stem, publish, render,
    validate_count, write_photo, Dimensions, Format, Frame, GeometryRequest, Matte, NameRequest,
    Overlay, Raster, MAX_BATCH_PHOTOS, SRGB_PROFILE,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::Cursor;

fn size(width: u32, height: u32) -> Dimensions {
    Dimensions { width, height }
}

#[test]
fn bounded_unique_photos_keep_catalog_order() {
    let candidates: Vec<_> = (0..1200).map(|id| id.to_string()).collect();
    assert_eq!(MAX_BATCH_PHOTOS, 200);
    for count in [199, 200] {
        assert!(validate_count(count).is_ok());
    }
    for count in [0, 201, 1200] {
        assert!(validate_count(count).is_err());
    }
    let reversed: Vec<_> = candidates[..200].iter().rev().cloned().collect();
    assert_eq!(
        ordered_selection(&candidates, &reversed).unwrap(),
        candidates[..200]
    );
    assert!(ordered_selection(&candidates, &["outside".into()]).is_err());
    assert!(ordered_selection(&candidates, &["12".into(), "12".into()]).is_err());
}

#[test]
fn output_name_substitutes_once_and_preserves_dots_and_unicode() {
    let mut request = NameRequest {
        template: "{name}-{index}-{captureDate}".to_owned(),
        stem: "山谷.v2{date}".to_owned(),
        index: 7,
        export_date: "20261122".to_owned(),
        capture_date: Some("20260918".to_owned()),
    };
    assert_eq!(
        output_stem(&request).unwrap(),
        "山谷.v2{date}-0007-20260918"
    );
    request.capture_date = None;
    assert!(output_stem(&request).is_err());
    request.template = "..\\{name}".into();
    assert!(output_stem(&request).is_err());
}

#[test]
fn percent_mat_and_cover_use_canvas_coordinates_and_do_not_enlarge() {
    let frame = Frame {
        ratio: Some([4, 5]),
        margin_percent: 5,
        footer_per_mille: 150,
        cover: false,
    };
    let source = size(6000, 4000);
    let result = geometry(GeometryRequest {
        source,
        long_edge: Some(1350),
        frame: Some(frame),
    })
    .unwrap();
    assert_eq!(result.canvas, size(1080, 1350));
    assert_eq!(result.footer.height, 162);
    assert!(result.photo.y + result.photo.height <= result.footer.y);
    let tiny = geometry(GeometryRequest {
        source: size(1200, 21),
        long_edge: Some(1350),
        frame: Some(Frame {
            cover: true,
            ..frame
        }),
    })
    .unwrap();
    assert!(tiny.photo.height <= 21);
    let one = geometry(GeometryRequest {
        source: size(1, 1),
        long_edge: None,
        frame: Some(frame),
    })
    .unwrap();
    assert_eq!(one.canvas, size(1, 1));
    assert!(geometry(GeometryRequest {
        source: size(0, 20),
        long_edge: None,
        frame: None
    })
    .is_err());
}

#[test]
fn transparent_overlay_and_two_backgrounds_change_only_expected_pixels() {
    let source = [65535, 0, 0, 65535, 17, 28, 65535, 65535];
    let dimensions = size(2, 1);
    let raster = Raster {
        pixels: &source,
        size: dimensions,
    };
    let plan = geometry(GeometryRequest {
        source: dimensions,
        long_edge: None,
        frame: None,
    })
    .unwrap();
    assert_eq!(
        render(raster, &plan, Matte::Transparent, &[]).unwrap(),
        source
    );
    let logo = [0, 65535, 0, 32768];
    let changed = render(
        raster,
        &plan,
        Matte::Solid([65535; 4]),
        &[Overlay {
            x: 1,
            y: 0,
            raster: Raster {
                pixels: &logo,
                size: size(1, 1),
            },
        }],
    )
    .unwrap();
    assert_eq!(&changed[..4], &source[..4]);
    assert!((32767..=32768).contains(&changed[6]));
    assert_eq!(changed[7], 65535);

    let framed = geometry(GeometryRequest {
        source: size(40, 24),
        long_edge: Some(32),
        frame: Some(Frame {
            ratio: Some([4, 5]),
            margin_percent: 11,
            footer_per_mille: 120,
            cover: false,
        }),
    })
    .unwrap();
    let stripe = [1000, 50000, 2000, 65535].repeat(960);
    let striped = Raster {
        pixels: &stripe,
        size: size(40, 24),
    };
    assert_ne!(
        render(striped, &framed, Matte::Blur, &[]).unwrap(),
        render(striped, &framed, Matte::Solid([65535; 4]), &[]).unwrap()
    );
}

#[test]
fn three_real_encoders_preserve_srgb_geometry_and_depth() {
    let samples = [633, 30_005, 63_099, 12_345, 17, 65_111, 3_888, 65_535];
    let raster = Raster {
        pixels: &samples,
        size: size(2, 1),
    };
    for format in [Format::Png, Format::Tiff, Format::Jpeg] {
        let mut file = Cursor::new(Vec::new());
        encode(&mut file, raster, format, 90).unwrap();
        let bytes = file.into_inner();
        match format {
            Format::Png => {
                let mut reader = png::Decoder::new(Cursor::new(&bytes)).read_info().unwrap();
                assert_eq!(reader.info().bit_depth, png::BitDepth::Sixteen);
                assert_eq!(reader.info().icc_profile.as_deref(), Some(SRGB_PROFILE));
                let mut data = vec![0; reader.output_buffer_size().unwrap()];
                reader.next_frame(&mut data).unwrap();
                assert_eq!(
                    data,
                    samples
                        .iter()
                        .flat_map(|value| value.to_be_bytes())
                        .collect::<Vec<_>>()
                );
            }
            Format::Tiff => {
                let mut reader = tiff::decoder::Decoder::new(Cursor::new(&bytes)).unwrap();
                assert_eq!(reader.dimensions().unwrap(), (2, 1));
                assert_eq!(
                    reader.get_tag_u8_vec(tiff::tags::Tag::IccProfile).unwrap(),
                    SRGB_PROFILE
                );
                assert_eq!(
                    reader
                        .get_tag_u16_vec(tiff::tags::Tag::ExtraSamples)
                        .unwrap(),
                    [2]
                );
                let tiff::decoder::DecodingResult::U16(data) = reader.read_image().unwrap() else {
                    panic!("missing 16-bit TIFF")
                };
                assert_eq!(data, samples);
            }
            Format::Jpeg => {
                assert!(bytes
                    .windows(SRGB_PROFILE.len())
                    .any(|window| window == SRGB_PROFILE));
                let decoded = turbojpeg::decompress(&bytes, turbojpeg::PixelFormat::RGB).unwrap();
                assert_eq!((decoded.width, decoded.height), (2, 1));
            }
        }
    }
}

#[test]
fn no_overwrite_in_rust_delivery_and_publish() {
    let dir = tempfile::tempdir().unwrap();
    let final_path = dir.path().join("sample.jpg");
    let stage = dir.path().join("on-same-volume");
    std::fs::write(&stage, b"other batch").unwrap();
    let raster = Raster {
        pixels: &[3000, 6000, 9000, 65535],
        size: size(1, 1),
    };
    let geometry = geometry(GeometryRequest {
        source: raster.size,
        long_edge: None,
        frame: None,
    })
    .unwrap();
    write_photo(
        &final_path,
        raster,
        &geometry,
        Matte::Transparent,
        &[],
        Format::Jpeg,
        90,
    )
    .unwrap();
    let before = std::fs::read(&final_path).unwrap();
    assert!(publish(&stage, &final_path).is_err());
    assert_eq!(std::fs::read(&final_path).unwrap(), before);
}

const PORTFOLIO: &[u8] =
    include_bytes!("../../../specs/032-export-workspace/assets/portfolio.rmexport.json");

#[test]
fn preset_v1_upgrade_keeps_printing_settings_without_device_data() {
    let mut version: Value = serde_json::from_slice(PORTFOLIO).unwrap();
    version["schemaVersion"] = json!(1);
    for key in ["mode", "copyMode", "originalFormat"] {
        version["settings"].as_object_mut().unwrap().remove(key);
    }
    version["settings"]["layout"]
        .as_object_mut()
        .unwrap()
        .remove("builtin");
    let result: Value =
        serde_json::from_slice(&normalize_preset(&serde_json::to_vec(&version).unwrap()).unwrap())
            .unwrap();
    assert_eq!(result["schemaVersion"], 2);
    assert_eq!(result["settings"]["mode"], "render");
    assert_eq!(result["settings"]["layout"]["builtin"], "paper");
    version["settings"]["destination"] = json!("elsewhere");
    assert!(normalize_preset(&serde_json::to_vec(&version).unwrap()).is_err());
}

#[test]
fn a_disabled_logo_and_opacity_are_preserved_and_bad_resources_rejected() {
    let mut version: Value = serde_json::from_slice(PORTFOLIO).unwrap();
    let raster = Raster {
        pixels: &[0, 1000, 10000, 32768],
        size: size(1, 1),
    };
    let mut file = Cursor::new(Vec::new());
    encode(&mut file, raster, Format::Png, 95).unwrap();
    let png = file.into_inner();
    let logo = json!({"mime": "image/png", "base64":STANDARD.encode(&png), "sha256":format!("{:x}", Sha256::digest(&png))});
    version["settings"]["layout"]["logo"] = logo.clone();
    version["settings"]["layout"]["mark"] = json!("off");
    version["settings"]["layout"]["opacity"] = json!(0);
    let result: Value =
        serde_json::from_slice(&normalize_preset(&serde_json::to_vec(&version).unwrap()).unwrap())
            .unwrap();
    assert_eq!(result["settings"]["layout"]["logo"], logo);
    assert_eq!(result["settings"]["layout"]["opacity"], 0);
    version["settings"]["layout"]["logo"]["sha256"] = json!("0".repeat(64));
    assert!(normalize_preset(&serde_json::to_vec(&version).unwrap()).is_err());
}
