use rawmaster_server_poc::queue::{JobKind, JobQueue, JobRequest, Lane, SubmitOutcome};
use rawmaster_server_poc::scene;
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("scene") => {
            let path = args.get(2).expect("usage: server-poc scene <scene.json>");
            let bytes = fs::read(path).expect("read scene fixture");
            let (document, receipt) = scene::parse(&bytes).expect("valid scene graph");
            println!(
                "{}",
                serde_json::json!({
                    "schemaVersion": document.schema_version,
                    "output": document.graph.output.0,
                    "receipt": receipt,
                })
            );
        }
        Some("queue") => {
            let mut queue = JobQueue::new();
            let request = JobRequest {
                library_id: "library-demo".into(),
                job_id: "job-1".into(),
                kind: JobKind::SceneRenderFinal,
                lane: Lane::SceneFinal,
                priority: 10,
                request_hash: "request-sha".into(),
                input_content_ids: vec!["sha256:demo:1".into()],
                scene_graph_hash: Some("scene-sha".into()),
                output_state_hash: Some("output-sha".into()),
                model_program_hash: None,
                compatibility_route: Some("scene-graph".into()),
                delivery_target: Some("hdr2020".into()),
                format: Some("avif10".into()),
                template_id: None,
                batch_id: None,
                target_head: Some("head-1".into()),
            };
            let (outcome, _) = queue.submit(request);
            println!(
                "{}",
                serde_json::json!({
                    "submit": match outcome { SubmitOutcome::Created => "created", SubmitOutcome::Existing => "existing", SubmitOutcome::Conflict => "conflict", SubmitOutcome::Invalid => "invalid" },
                    "pending": queue.pending(),
                })
            );
        }
        _ => {
            eprintln!("usage: server-poc scene <scene.json> | queue");
            std::process::exit(2);
        }
    }
}
