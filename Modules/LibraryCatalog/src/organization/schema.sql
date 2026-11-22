CREATE TABLE lc_org_volumes(
 volume_id TEXT PRIMARY KEY NOT NULL,name TEXT NOT NULL,locator TEXT,online INTEGER,revision INTEGER NOT NULL
);
CREATE TABLE lc_org_folders(
 folder_id TEXT PRIMARY KEY NOT NULL,volume_id TEXT NOT NULL REFERENCES lc_org_volumes,
 parent_id TEXT REFERENCES lc_org_folders,name TEXT NOT NULL,position INTEGER NOT NULL,revision INTEGER NOT NULL
);
CREATE INDEX lc_org_folder_children ON lc_org_folders(volume_id,parent_id,position,folder_id);
CREATE TABLE lc_org_works(
 work_id TEXT PRIMARY KEY NOT NULL,kind TEXT NOT NULL CHECK(kind IN('original','offline','virtual','derivedPhoto','derivedVideo')),
 file_id TEXT REFERENCES lc_files,master_work_id TEXT REFERENCES lc_org_works,folder_id TEXT REFERENCES lc_org_folders,
 name TEXT,rating INTEGER CHECK(rating BETWEEN 0 AND 5),metadata_json TEXT NOT NULL DEFAULT '{}',
 active_version_id TEXT,revision INTEGER NOT NULL,project_id TEXT,
 CHECK((kind='original' AND file_id IS NOT NULL AND master_work_id IS NULL)
    OR (kind IN('offline','derivedPhoto','derivedVideo') AND file_id IS NULL AND master_work_id IS NULL)
    OR (kind='virtual' AND file_id IS NULL AND master_work_id IS NOT NULL))
);
CREATE INDEX lc_org_file_works ON lc_org_works(file_id,work_id);
CREATE INDEX lc_org_master_works ON lc_org_works(master_work_id,work_id);
CREATE INDEX lc_org_folder_works ON lc_org_works(folder_id,work_id);
CREATE TABLE lc_org_derived(work_id TEXT PRIMARY KEY NOT NULL REFERENCES lc_org_works,
 resource_id TEXT NOT NULL REFERENCES lc_resources(resource_id),job_id TEXT NOT NULL UNIQUE);
CREATE TABLE lc_org_versions(
 version_id TEXT PRIMARY KEY NOT NULL,work_id TEXT NOT NULL REFERENCES lc_org_works,
 parent_version_id TEXT REFERENCES lc_org_versions,appearance_json TEXT NOT NULL,position INTEGER NOT NULL,
 UNIQUE(work_id,position)
);
CREATE TABLE lc_org_collections(
 collection_id TEXT PRIMARY KEY NOT NULL,parent_id TEXT REFERENCES lc_org_collections,
 kind TEXT NOT NULL CHECK(kind IN('group','regular','smart')),name TEXT NOT NULL,rule_json TEXT,
 position INTEGER NOT NULL,revision INTEGER NOT NULL,
 CHECK((kind='smart')=(rule_json IS NOT NULL))
);
CREATE INDEX lc_org_collection_children ON lc_org_collections(parent_id,position,collection_id);
CREATE TABLE lc_org_collection_members(
 collection_id TEXT NOT NULL REFERENCES lc_org_collections ON DELETE CASCADE,work_id TEXT NOT NULL REFERENCES lc_org_works,
 position INTEGER NOT NULL,PRIMARY KEY(collection_id,work_id),UNIQUE(collection_id,position)
);
CREATE INDEX lc_org_member_work ON lc_org_collection_members(work_id,collection_id);
CREATE TABLE lc_org_member_imports(import_id TEXT PRIMARY KEY NOT NULL,collection_id TEXT NOT NULL REFERENCES lc_org_collections,
 base_revision INTEGER NOT NULL,published_revision INTEGER,expected_count INTEGER);
CREATE TABLE lc_org_member_parts(import_id TEXT NOT NULL REFERENCES lc_org_member_imports ON DELETE CASCADE,
 start INTEGER NOT NULL,n INTEGER NOT NULL,digest TEXT NOT NULL,PRIMARY KEY(import_id,start));
CREATE TABLE lc_org_member_stage(import_id TEXT NOT NULL REFERENCES lc_org_member_imports ON DELETE CASCADE,
 position INTEGER NOT NULL,work_id TEXT NOT NULL REFERENCES lc_org_works,PRIMARY KEY(import_id,position),UNIQUE(import_id,work_id));
CREATE TABLE lc_org_folder_order(
 folder_id TEXT NOT NULL REFERENCES lc_org_folders,work_id TEXT NOT NULL REFERENCES lc_org_works,
 position INTEGER NOT NULL,PRIMARY KEY(folder_id,work_id),UNIQUE(folder_id,position)
);
CREATE TABLE lc_org_stacks(
 stack_id TEXT PRIMARY KEY NOT NULL,scope_kind TEXT NOT NULL CHECK(scope_kind IN('folder','collection')),
 scope_id TEXT NOT NULL,cover_work_id TEXT NOT NULL REFERENCES lc_org_works,collapsed INTEGER NOT NULL,
 revision INTEGER NOT NULL,UNIQUE(stack_id,scope_kind,scope_id)
);
CREATE TABLE lc_org_stack_members(
 stack_id TEXT NOT NULL,scope_kind TEXT NOT NULL,scope_id TEXT NOT NULL,
 work_id TEXT NOT NULL REFERENCES lc_org_works,position INTEGER NOT NULL,
 PRIMARY KEY(stack_id,work_id),UNIQUE(stack_id,position),UNIQUE(scope_kind,scope_id,work_id),
 FOREIGN KEY(stack_id,scope_kind,scope_id) REFERENCES lc_org_stacks(stack_id,scope_kind,scope_id) ON DELETE CASCADE
);
CREATE VIEW lc_org_visible_sources AS
 SELECT w.work_id,w.kind,base.work_id AS base_work_id,base.file_id AS source_file_id,base.folder_id AS source_folder_id,
  coalesce(w.project_id,base.project_id) AS work_project_id
 FROM lc_org_works w JOIN lc_org_works base ON base.work_id=coalesce(w.master_work_id,w.work_id)
 WHERE base.kind='offline' OR EXISTS(SELECT 1 FROM lc_org_derived d WHERE d.work_id=base.work_id)
    OR EXISTS(SELECT 1 FROM lc_catalog_files f WHERE f.file_id=base.file_id);
-- Native grants and initial migration feed the same trigger. This input table
-- is emptied by the trigger in the originating transaction.
CREATE TABLE lc_org_native_seed(file_id TEXT NOT NULL,root_id TEXT,relative_path TEXT);
CREATE TRIGGER lc_org_seed_native AFTER INSERT ON lc_org_native_seed BEGIN
 INSERT OR IGNORE INTO lc_org_volumes(volume_id,name,revision)
 SELECT new.root_id,new.root_id,1 WHERE new.root_id IS NOT NULL AND new.root_id!='';
 INSERT OR IGNORE INTO lc_org_folders(folder_id,volume_id,parent_id,name,position,revision)
 SELECT 'dir:'||hex(new.root_id)||':'||hex(path),new.root_id,
     CASE WHEN parent IS NOT NULL THEN 'dir:'||hex(new.root_id)||':'||hex(parent) END,
     CASE WHEN parent IS NULL THEN '/' ELSE name END,0,1
 FROM (WITH RECURSIVE paths(path,parent,name,tail,depth) AS (
    SELECT '',NULL,'',coalesce(new.relative_path,''),0
    UNION ALL SELECT CASE WHEN path='' THEN '' ELSE path||'/' END||substr(tail,1,instr(tail,'/')-1),
      path,substr(tail,1,instr(tail,'/')-1),substr(tail,instr(tail,'/')+1),depth+1
      FROM paths WHERE instr(tail,'/')>1)
    SELECT * FROM paths ORDER BY depth)
 WHERE new.root_id IS NOT NULL AND new.root_id!='';
 INSERT INTO lc_org_works(work_id,kind,file_id,folder_id,revision)
 VALUES('file:'||new.file_id,'original',new.file_id,
   (SELECT folder_id FROM lc_org_folders
      WHERE volume_id=new.root_id AND folder_id='dir:'||hex(new.root_id)||':'||hex(
       CASE WHEN instr(coalesce(new.relative_path,''),'/')=0 THEN '' ELSE
        rtrim(substr(new.relative_path,1,length(new.relative_path)-length(
         (WITH RECURSIVE tail(s) AS (SELECT new.relative_path UNION ALL SELECT substr(s,instr(s,'/')+1) FROM tail WHERE instr(s,'/')>0)
          SELECT s FROM tail WHERE instr(s,'/')=0))),'/') END)),1)
 ON CONFLICT(work_id) DO UPDATE SET folder_id=coalesce(lc_org_works.folder_id,excluded.folder_id);
 DELETE FROM lc_org_native_seed WHERE rowid=new.rowid;
END;
CREATE TRIGGER lc_org_on_scope AFTER INSERT ON lc_scopes BEGIN
 INSERT INTO lc_org_native_seed(file_id,root_id,relative_path)
 SELECT new.file_id,o.root_id,o.relative_path FROM lc_occurrences o WHERE o.session_id=new.session_id AND o.occurrence_id=new.occurrence_id;
END;
