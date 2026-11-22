WITH selected(file_id) AS MATERIALIZED (SELECT value FROM json_each(?1)),
legacy AS MATERIALIZED (
    SELECT f.file_id,g.project_id,m.group_id,min(m.position) AS position,
           max(m.included) AS included,min(m.rowid) AS appearance
    FROM lc_asset_files f JOIN membership m ON m.asset_id=f.asset_id JOIN groups_data g ON g.id=m.group_id
    WHERE f.file_id IN selected GROUP BY f.file_id,g.project_id,m.group_id
),
current AS (
    SELECT m.file_id,v.project_id,m.group_id,m.position,m.included
    FROM lc_group_file_members m
    JOIN lc_group_versions v ON v.group_id=m.group_id AND v.revision=m.revision
    WHERE m.file_id IN selected AND v.tombstoned=0
      AND m.revision=(SELECT max(n.revision) FROM lc_group_versions n WHERE n.group_id=m.group_id)
      AND NOT EXISTS(SELECT 1 FROM lc_group_dirty d WHERE d.group_id=m.group_id)
)
SELECT file_id,project_id,group_id,position,included,appearance FROM legacy l
WHERE NOT EXISTS(SELECT 1 FROM lc_group_versions v WHERE v.group_id=l.group_id)
   OR EXISTS(SELECT 1 FROM lc_group_dirty d WHERE d.group_id=l.group_id)
UNION ALL
SELECT c.file_id,c.project_id,c.group_id,c.position,c.included,coalesce(l.appearance,9223372036854775807)
FROM current c LEFT JOIN legacy l USING(file_id,project_id,group_id)
ORDER BY 6,3
