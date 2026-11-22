-- Trusted reference for compiling triggers, views and integration fixtures. The
-- Swift schema validator owns the complete legacy table/index verification.
CREATE TABLE projects(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE sessions(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE assets(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,source_path TEXT NOT NULL,data TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,UNIQUE(session_id,source_path));
CREATE TABLE groups_data(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,data TEXT NOT NULL);
CREATE TABLE membership(group_id TEXT NOT NULL,asset_id TEXT NOT NULL,position INTEGER NOT NULL,included INTEGER NOT NULL,PRIMARY KEY(group_id,asset_id));
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE operations(id TEXT PRIMARY KEY,device_id TEXT NOT NULL,entity_id TEXT NOT NULL,base_revision INTEGER NOT NULL,resulting_revision INTEGER NOT NULL,payload_version INTEGER NOT NULL,action TEXT NOT NULL,payload TEXT NOT NULL,timestamp REAL NOT NULL);
CREATE TABLE session_workflows(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE workflow_completions(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE capture_pairs(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE pair_dismissals(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE group_commands(id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE project_admissions(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE triage_records(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE asset_tags(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE asset_color_labels(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE review_records(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE quality_evidence(asset_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE project_review_states(project_id TEXT PRIMARY KEY,data TEXT NOT NULL);
CREATE TABLE editing_works(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,asset_id TEXT NOT NULL,data TEXT NOT NULL);
CREATE TABLE editing_versions(id TEXT PRIMARY KEY,work_id TEXT NOT NULL,parent_id TEXT,data TEXT NOT NULL);
CREATE TABLE editing_dispositions(version_id TEXT PRIMARY KEY,disposition TEXT NOT NULL);
CREATE TABLE editing_exports(id TEXT PRIMARY KEY,work_id TEXT NOT NULL,command_id TEXT NOT NULL,data TEXT NOT NULL);
CREATE TABLE archive_publications(id TEXT PRIMARY KEY,version_id TEXT NOT NULL,data TEXT NOT NULL);
