WITH RECURSIVE
origins AS (
 SELECT w.work_id,w.rowid AS rendition_ord,w.kind,w.name,w.rating AS work_rating,w.active_version_id,v.base_work_id,v.source_file_id,v.source_folder_id,
    coalesce(f.project_id,v.work_project_id,'') AS project_id,f.capture_id,f.asset_id,a.session_id,a.rowid AS asset_ord,s.rowid AS session_ord,
    coalesce(a.data,'{}') AS record,base.metadata_json AS base_meta,w.metadata_json AS work_meta,
    coalesce(t.data,'[]') AS legacy_tags,json_extract(l.data,'$.label') AS legacy_label,
    coalesce(json_extract(rr.data,'$.reviewed'),0) AS reviewed,
    coalesce((SELECT sc.content_id FROM lc_scopes sc JOIN lc_asset_input ai ON ai.asset_id=sc.asset_id AND ai.content_id=sc.content_id
      WHERE sc.project_id=f.project_id AND sc.file_id=f.file_id AND sc.asset_id=f.asset_id ORDER BY sc.rowid DESC LIMIT 1),
     (SELECT sc.content_id FROM lc_scopes sc WHERE sc.project_id=f.project_id AND sc.file_id=f.file_id AND sc.asset_id=f.asset_id ORDER BY sc.rowid DESC LIMIT 1)) AS content_id,
    coalesce((SELECT min(sc.kind='sequenceOnly') FROM lc_scopes sc WHERE sc.file_id=f.file_id AND sc.project_id=f.project_id),0) AS sequence_only,
    file.role,der.resource_id,der.job_id,fo.volume_id
 FROM lc_org_visible_sources v JOIN lc_org_works w ON w.work_id=v.work_id
 JOIN lc_org_works base ON base.work_id=v.base_work_id
 LEFT JOIN lc_catalog_files f ON f.file_id=v.source_file_id AND (v.work_project_id IS NULL OR v.work_project_id=f.project_id)
 LEFT JOIN lc_files file ON file.file_id=f.file_id LEFT JOIN assets a ON a.id=f.asset_id
 LEFT JOIN sessions s ON s.id=a.session_id LEFT JOIN asset_tags t ON t.asset_id=a.id
 LEFT JOIN asset_color_labels l ON l.asset_id=a.id LEFT JOIN review_records rr ON rr.asset_id=a.id
 LEFT JOIN lc_org_folders fo ON fo.folder_id=v.source_folder_id LEFT JOIN lc_org_derived der ON der.work_id=v.base_work_id
 WHERE (v.source_file_id IS NULL OR f.file_id IS NOT NULL) AND (__ANCHOR__)
),
effective AS MATERIALIZED (
 SELECT o.*,rm_org_meta(record,base_meta,work_meta,__FILE_EFFECTIVE__,work_rating,__WORK_EFFECTIVE__) AS meta
 FROM origins o
),
display AS MATERIALIZED (
 SELECT e.*,coalesce(json_extract(meta,'$.filename'),name,work_id) AS filename,
     coalesce(name,json_extract(meta,'$.filename'),work_id) AS display_name,
     json_array(work_id,project_id,asset_id) AS doc,
     rm_org_tags(meta,legacy_tags) AS tag_array
 FROM effective e
),
documents AS (
 SELECT d.*,0 AS gen,source_file_id AS file_id,coalesce(json_extract(meta,'$.relativePath'),filename) AS relative_path,
   rm_org_fold(__NAME_FOR_SEARCH__) AS name_key,rm_org_fold(display_name) AS work_name,
   json_extract(meta,'$.camera') AS camera,rm_org_fold(trim(json_extract(meta,'$.camera'))) AS camera_key,
   rm_org_number(json_extract(meta,'$.capturedAt')) AS captured,
   coalesce(rm_org_number(json_extract(meta,'$.rating')),0) AS rating,
   coalesce(json_extract(meta,'$.decision'),'undecided') AS decision,
   CASE WHEN json_type(meta,'$.colorLabel') IS NOT NULL THEN nullif(json_extract(meta,'$.colorLabel'),'none') ELSE legacy_label END AS color_label,
   CASE WHEN source_file_id IS NULL THEN CASE WHEN resource_id IS NOT NULL THEN 'available' ELSE 'missing' END
     ELSE coalesce(json_extract(meta,'$.availability'),'missing') END AS availability,
   rm_org_format(filename) AS format,
   rm_org_fold(display_name||char(31)||filename||char(31)||coalesce(json_extract(meta,'$.title'),'')||char(31)||
     coalesce(json_extract(meta,'$.caption'),'')||char(31)||coalesce(json_extract(meta,'$.place'),'')||char(31)||
     coalesce(json_extract(meta,'$.creator'),'')||char(31)||coalesce(json_extract(meta,'$.copyright'),'')||char(31)||
     coalesce((SELECT group_concat(value,char(31)) FROM json_each(tag_array)),'')||char(31)||
     coalesce(json_extract(meta,'$.camera'),'')||char(31)||coalesce(json_extract(meta,'$.lens'),'')) AS body,
   json_extract(meta,'$.title') AS title,json_extract(meta,'$.caption') AS caption,json_extract(meta,'$.place') AS place,
   json_extract(meta,'$.creator') AS creator,json_extract(meta,'$.copyright') AS copyright,json_extract(meta,'$.lens') AS lens,
   coalesce(json_extract(meta,'$.flag'),CASE json_extract(meta,'$.decision') WHEN 'keep' THEN 'picked' WHEN 'reject' THEN 'rejected' ELSE 'unflagged' END) AS flag,
   json_extract(meta,'$.colorSpace') AS color_space,rm_org_number(json_extract(meta,'$.iso')) AS iso,
   rm_org_number(json_extract(meta,'$.aperture')) AS aperture,rm_org_number(json_extract(meta,'$.shutterSeconds')) AS shutter_seconds,
   rm_org_number(json_extract(meta,'$.focalLength')) AS focal_length,rm_org_number(json_extract(meta,'$.exposureCompensation')) AS exposure_compensation,
   rm_org_number(json_extract(meta,'$.width')) AS width,rm_org_number(json_extract(meta,'$.height')) AS height,
   rm_org_number(json_extract(meta,'$.latitude')) AS latitude,rm_org_number(json_extract(meta,'$.longitude')) AS longitude,
   (rm_org_number(json_extract(meta,'$.latitude')) BETWEEN -90 AND 90 AND rm_org_number(json_extract(meta,'$.longitude')) BETWEEN -180 AND 180) IS TRUE AS has_gps,
   json_extract(meta,'$.focusMachine') AS focus_machine,json_extract(meta,'$.focusManual') AS focus_manual,
   json_extract(meta,'$.focusEffective') AS focus_effective,
   (active_version_id IS NOT NULL OR EXISTS(SELECT 1 FROM editing_works ew WHERE ew.asset_id=d.asset_id)) AS edited,
   EXISTS(SELECT 1 FROM editing_works ew JOIN editing_exports ee ON ee.work_id=ew.id WHERE ew.asset_id=d.asset_id) AS exported
 FROM display d
),
doc_tags AS (
 SELECT d.doc,rm_org_tag(j.value) AS key,j.value AS display FROM documents d,json_each(d.tag_array) j
),
doc_groups AS (
 SELECT d.doc,m.group_id,m.position FROM documents d JOIN lc_group_file_members m ON m.file_id=d.source_file_id
 JOIN lc_group_versions v ON v.group_id=m.group_id AND v.revision=m.revision AND v.project_id=d.project_id AND v.tombstoned=0
 WHERE v.revision=(SELECT max(n.revision) FROM lc_group_versions n WHERE n.group_id=v.group_id)
 AND NOT EXISTS(SELECT 1 FROM lc_group_dirty g WHERE g.group_id=v.group_id)
 UNION ALL
 SELECT d.doc,m.group_id,m.position FROM documents d JOIN membership m ON m.asset_id=d.asset_id JOIN groups_data g ON g.id=m.group_id AND g.project_id=d.project_id
 WHERE NOT EXISTS(SELECT 1 FROM lc_group_versions n WHERE n.group_id=m.group_id) OR EXISTS(SELECT 1 FROM lc_group_dirty x WHERE x.group_id=m.group_id)
)
