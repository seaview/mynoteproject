# Tiny local server for the notes app. Storage: SQLite (sqlite3.exe next to this script, no install).
# Set NOTE_PORT / NOTE_DB to run a test copy on another port / database file.
$port = if ($env:NOTE_PORT) { [int]$env:NOTE_PORT } else { 8766 }
$root = $PSScriptRoot
$db = if ($env:NOTE_DB) { $env:NOTE_DB } else { Join-Path $root 'notes.db' }
$sqlite = Join-Path $root 'sqlite3.exe'
$legacy = if ($env:NOTE_LEGACY) { $env:NOTE_LEGACY } else { Join-Path $root 'notes.json' }   # old pre-database data, imported once
$utf8 = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Web

if (-not (Test-Path $sqlite)) { Write-Host "sqlite3.exe not found next to server.ps1." -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }

# Run SQL with sqlite3.exe. User data never goes into the SQL text: it is read from temp files
# into temp tables, and the SQL refers to it as @P (query parameters JSON) and @J (request body JSON).
function Run-Sql([string]$sql, $params = $null, [string]$bodyFile = $null) {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("notes-" + [guid]::NewGuid().ToString('N'))
  $files = @("$tmp.sql")
  try {
    $pre = ".bail on`n.timeout 5000`nPRAGMA foreign_keys=ON;`n"
    if ($null -ne $params) {
      [IO.File]::WriteAllText("$tmp.p.json", (ConvertTo-Json -InputObject $params -Compress -Depth 5), $utf8); $files += "$tmp.p.json"
      $pre += "CREATE TEMP TABLE prm AS SELECT CAST(readfile('$(("$tmp.p.json") -replace '\\','/')') AS TEXT) AS p;`n"
    }
    if ($bodyFile) { $pre += "CREATE TEMP TABLE bdy AS SELECT CAST(readfile('$(($bodyFile) -replace '\\','/')') AS TEXT) AS j;`n" }
    $body = $sql.Replace('@P', '(SELECT p FROM prm)').Replace('@J', '(SELECT j FROM bdy)')
    [IO.File]::WriteAllText("$tmp.sql", $pre + $body + "`n", $utf8)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $sqlite
    $psi.Arguments = "-batch `"$db`" `".read '$(("$tmp.sql") -replace '\\','/')'`""
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -or $errTask.Result.Trim()) { throw "sqlite: $($errTask.Result)" }
    return $out.Trim()
  }
  finally { foreach ($f in $files) { Remove-Item $f -ErrorAction SilentlyContinue } }
}

$null = Run-Sql ([IO.File]::ReadAllText((Join-Path $root 'schema.sql'), $utf8))

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() }
catch {
  Write-Host "Could not start on port $port (is the server already running?)." -ForegroundColor Red
  Write-Host "If it is, just open http://localhost:$port/ in your browser."
  Read-Host 'Press Enter to close'
  exit 1
}
Write-Host "Notes app running at http://localhost:$port/"
Write-Host "Notes are saved in: $db"
Write-Host "Close this window to stop the server."
if (-not $env:NOTE_NO_BROWSER) { Start-Process "http://localhost:$port/" }

function Send($ctx, [int]$status, [string]$type, [string]$body) {
  $bytes = $utf8.GetBytes($body)
  $ctx.Response.StatusCode = $status
  $ctx.Response.ContentType = $type
  $ctx.Response.Headers.Add('Cache-Control', 'no-store')
  $ctx.Response.ContentLength64 = $bytes.Length
  $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $ctx.Response.Close()
}
function SendJson($ctx, [string]$json) { Send $ctx 200 'application/json; charset=utf-8' $json }

$NOTE_COLS = "'id',n.id,'title',n.title,'nb',n.nb,'pinned',n.pinned,'trashed',n.trashed,'created',n.created,'updated',n.updated,'tags',json((SELECT json_group_array(tag) FROM note_tags WHERE note_id=n.id)),'att',(SELECT count(*) FROM attachments WHERE note_id=n.id)"
$UPSERT_VALUES = "COALESCE(json_extract(@J,'`$.title'),''), COALESCE(json_extract(@J,'`$.html'),''), COALESCE(json_extract(@J,'`$.text'),''), COALESCE(json_extract(@J,'`$.nb'),1), COALESCE(json_extract(@J,'`$.pinned'),0), COALESCE(json_extract(@J,'`$.trashed'),0), COALESCE(json_extract(@J,'`$.created'),CAST(strftime('%s','now') AS INT)*1000), COALESCE(json_extract(@J,'`$.updated'),CAST(strftime('%s','now') AS INT)*1000)"
$AFTER_UPSERT = @"
DELETE FROM note_tags WHERE note_id=(SELECT id FROM cur);
INSERT OR IGNORE INTO note_tags(note_id,tag) SELECT (SELECT id FROM cur), value FROM json_each(@J,'`$.tags') WHERE value<>'';
DELETE FROM attachments WHERE note_id=(SELECT id FROM cur) AND json_type(@J,'`$.att')='array';
INSERT INTO attachments(note_id,name,type,size,data) SELECT (SELECT id FROM cur), json_extract(value,'`$.name'), json_extract(value,'`$.type'), json_extract(value,'`$.size'), json_extract(value,'`$.data') FROM json_each(@J,'`$.att');
DELETE FROM notes_fts WHERE rowid=(SELECT id FROM cur);
INSERT INTO notes_fts(rowid,title,text,tags) SELECT id, title, text, (SELECT group_concat(tag,' ') FROM note_tags WHERE note_id=notes.id) FROM notes WHERE id=(SELECT id FROM cur);
COMMIT;
SELECT json_object('id',(SELECT id FROM cur));
"@

function Build-List($qs) {
  $p = @{}
  $view = switch ($qs['view']) { 'trash' { 'trash' } 'pinned' { 'pinned' } default { 'all' } }
  $where = @("n.trashed=" + $(if ($view -eq 'trash') { 1 } else { 0 }))
  if ($view -eq 'pinned') { $where += 'n.pinned=1' }
  $n = 0L
  if ([long]::TryParse($qs['nb'], [ref]$n)) { $p.nb = $n; $where += "n.nb=json_extract(@P,'`$.nb')" }
  if ($qs['nbs']) { $ids = @(); foreach ($x in $qs['nbs'].Split(',')) { if ([long]::TryParse($x, [ref]$n)) { $ids += $n } }; $p.nbs = @($ids); $where += "n.nb IN (SELECT value FROM json_each(@P,'`$.nbs'))" }
  if ($qs['tag']) { $p.tag = $qs['tag']; $where += "EXISTS(SELECT 1 FROM note_tags t WHERE t.note_id=n.id AND t.tag=json_extract(@P,'`$.tag'))" }
  if ($qs['title']) { $p.title = $qs['title']; $where += "n.title LIKE '%'||replace(replace(replace(json_extract(@P,'`$.title'),'\','\\'),'%','\%'),'_','\_')||'%' ESCAPE '\'" }
  $field = if ($qs['field'] -eq 'created') { 'created' } else { 'updated' }
  $dated = $false
  if ([long]::TryParse($qs['from'], [ref]$n)) { $p.from = $n; $where += "n.$field>=json_extract(@P,'`$.from')"; $dated = $true }
  if ([long]::TryParse($qs['to'], [ref]$n)) { $p.to = $n; $where += "n.$field<=json_extract(@P,'`$.to')"; $dated = $true }
  if ($qs['has'] -eq 'image') { $where += "n.html LIKE '%<img%'" }
  if ($qs['has'] -eq 'attachment') { $where += "EXISTS(SELECT 1 FROM attachments a WHERE a.note_id=n.id)" }
  if ($qs['todo'] -eq 'true') { $where += "n.html LIKE '%data-done=""0""%'" }
  if ($qs['todo'] -eq 'false') { $where += "n.html NOT LIKE '%data-done=""0""%'" }
  $words = @(); foreach ($w in ([string]$qs['q'] -split '\s+')) { $w = $w -replace '["\x00-\x1f]', ''; if ($w) { $words += '"' + $w + '"*' } }
  $match = $words.Count -gt 0
  if ($match) { $p.m = ($words -join ' ') }
  $dir = if ($qs['order'] -eq 'asc') { 'ASC' } else { 'DESC' }
  $order = switch ($qs['sort']) {
    'title' { "n.title COLLATE NOCASE $dir" }
    'created' { "n.created $dir" }
    'relevance' { if ($match) { 'rank' } else { "n.updated $dir" } }
    default { "n.updated $dir" }
  }
  $browsing = -not ($match -or $qs['title'] -or $dated)
  if ($browsing) { $order = "n.pinned DESC, $order" }
  $snip = if ($match) { "snippet(notes_fts,1,'<<','>>','...',14)" } else { "substr(n.text,1,160)" }
  if ($match) { $where += "notes_fts MATCH json_extract(@P,'`$.m')" }
  $from = if ($match) { "notes_fts JOIN notes n ON n.id=notes_fts.rowid" } else { 'notes n' }
  $sql = "SELECT COALESCE(json_group_array(json(j)),'[]') FROM (SELECT json_object($NOTE_COLS,'snippet',$snip) AS j FROM $from WHERE $($where -join ' AND ') ORDER BY $order LIMIT 500);"
  return @{ sql = $sql; params = $p }
}

function Save-Body($ctx) {
  if ($ctx.Request.ContentType -notlike 'application/json*') { throw 'JSON only' }
  $f = Join-Path ([IO.Path]::GetTempPath()) ("notes-body-" + [guid]::NewGuid().ToString('N') + '.json')
  $fs = [IO.File]::Create($f); try { $ctx.Request.InputStream.CopyTo($fs) } finally { $fs.Dispose() }
  return $f
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $bodyFile = $null
  try {
    $path = $ctx.Request.Url.AbsolutePath
    $method = $ctx.Request.HttpMethod
    $qs = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query, $utf8)
    # Only answer requests addressed to localhost (blocks DNS-rebinding pages)
    if ($ctx.Request.Headers['Host'] -notmatch '^(localhost|127\.0\.0\.1)(:\d+)?$') { Send $ctx 403 'text/plain' 'Forbidden'; continue }
    $m = [regex]::Match($path, '^/api/notes/(\d+)$')

    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      Send $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllText((Join-Path $root 'index.html'), $utf8))
    }
    elseif ($method -eq 'GET' -and $path -eq '/api/notes') {
      $b = Build-List $qs
      SendJson $ctx (Run-Sql $b.sql $b.params)
    }
    elseif ($method -eq 'GET' -and $m.Success) {
      $r = Run-Sql "SELECT json_object('id',n.id,'title',n.title,'html',n.html,'text',n.text,'nb',n.nb,'pinned',n.pinned,'trashed',n.trashed,'created',n.created,'updated',n.updated,'tags',json((SELECT json_group_array(tag) FROM note_tags WHERE note_id=n.id)),'att',json((SELECT json_group_array(json_object('name',name,'type',type,'size',size,'data',data)) FROM attachments WHERE note_id=n.id))) FROM notes n WHERE n.id=json_extract(@P,'`$.id');" @{ id = [long]$m.Groups[1].Value }
      if ($r) { SendJson $ctx $r } else { Send $ctx 404 'text/plain' 'No such note' }
    }
    elseif ($method -eq 'POST' -and $path -eq '/api/notes') {
      $bodyFile = Save-Body $ctx
      $r = Run-Sql "CREATE TEMP TABLE chk(x INTEGER CHECK(x=1)); INSERT INTO chk SELECT json_valid(@J); CREATE TEMP TABLE cur(id INTEGER); BEGIN; INSERT INTO notes(title,html,text,nb,pinned,trashed,created,updated) VALUES($UPSERT_VALUES); INSERT INTO cur VALUES(last_insert_rowid()); $AFTER_UPSERT" $null $bodyFile
      SendJson $ctx $r
    }
    elseif ($method -eq 'PUT' -and $m.Success) {
      $bodyFile = Save-Body $ctx
      $r = Run-Sql "CREATE TEMP TABLE chk(x INTEGER CHECK(x=1)); INSERT INTO chk SELECT json_valid(@J); CREATE TEMP TABLE cur(id INTEGER); BEGIN; INSERT INTO cur VALUES(json_extract(@P,'`$.id')); INSERT INTO notes(id,title,html,text,nb,pinned,trashed,created,updated) VALUES((SELECT id FROM cur),$UPSERT_VALUES) ON CONFLICT(id) DO UPDATE SET title=excluded.title,html=excluded.html,text=excluded.text,nb=excluded.nb,pinned=excluded.pinned,trashed=excluded.trashed,created=excluded.created,updated=excluded.updated; $AFTER_UPSERT" @{ id = [long]$m.Groups[1].Value } $bodyFile
      SendJson $ctx $r
    }
    elseif ($method -eq 'DELETE' -and $m.Success) {
      $null = Run-Sql "BEGIN; DELETE FROM notes_fts WHERE rowid=json_extract(@P,'`$.id'); DELETE FROM notes WHERE id=json_extract(@P,'`$.id'); COMMIT;" @{ id = [long]$m.Groups[1].Value }
      Send $ctx 200 'text/plain' 'ok'
    }
    elseif ($method -eq 'DELETE' -and $path -eq '/api/notes' -and $qs['view'] -eq 'trash') {
      $null = Run-Sql "BEGIN; DELETE FROM notes_fts WHERE rowid IN (SELECT id FROM notes WHERE trashed=1); DELETE FROM notes WHERE trashed=1; COMMIT;"
      Send $ctx 200 'text/plain' 'ok'
    }
    elseif ($method -eq 'GET' -and $path -eq '/api/summary') {
      SendJson $ctx (Run-Sql "SELECT json_object('all',(SELECT count(*) FROM notes WHERE trashed=0),'pinned',(SELECT count(*) FROM notes WHERE trashed=0 AND pinned=1),'trash',(SELECT count(*) FROM notes WHERE trashed=1),'nb',json((SELECT COALESCE(json_group_object(nb,c),'{}') FROM (SELECT nb,count(*) c FROM notes WHERE trashed=0 GROUP BY nb))),'tags',json((SELECT COALESCE(json_group_object(tag,c),'{}') FROM (SELECT tag,count(*) c FROM note_tags t JOIN notes n ON n.id=t.note_id WHERE n.trashed=0 GROUP BY tag))));")
    }
    elseif ($method -eq 'GET' -and $path -eq '/api/meta') {
      SendJson $ctx (Run-Sql "SELECT COALESCE((SELECT json_group_object(key,json(value)) FROM meta),'{}');")
    }
    elseif ($method -eq 'PUT' -and $path -eq '/api/meta') {
      $bodyFile = Save-Body $ctx
      $null = Run-Sql "CREATE TEMP TABLE chk(x INTEGER CHECK(x=1)); INSERT INTO chk SELECT json_valid(@J); BEGIN; INSERT OR REPLACE INTO meta(key,value) SELECT key, CASE WHEN type IN ('array','object') THEN value ELSE CAST(value AS TEXT) END FROM json_each(@J) WHERE key IN ('notebooks','tasks','templates','nextId'); COMMIT;" $null $bodyFile
      Send $ctx 200 'text/plain' 'ok'
    }
    elseif ($method -eq 'POST' -and $path -eq '/api/move') {
      $bodyFile = Save-Body $ctx
      $null = Run-Sql "CREATE TEMP TABLE chk(x INTEGER CHECK(x=1)); INSERT INTO chk SELECT json_valid(@J); UPDATE notes SET nb=json_extract(@J,'`$.to') WHERE nb=json_extract(@J,'`$.from');" $null $bodyFile
      Send $ctx 200 'text/plain' 'ok'
    }
    elseif ($method -eq 'POST' -and $path -eq '/api/tag-rename') {
      $bodyFile = Save-Body $ctx
      $null = Run-Sql "CREATE TEMP TABLE chk(x INTEGER CHECK(x=1)); INSERT INTO chk SELECT json_valid(@J); BEGIN; UPDATE OR IGNORE note_tags SET tag=json_extract(@J,'`$.to') WHERE tag=json_extract(@J,'`$.from') AND json_extract(@J,'`$.to')<>''; DELETE FROM note_tags WHERE tag=json_extract(@J,'`$.from'); DELETE FROM notes_fts; INSERT INTO notes_fts(rowid,title,text,tags) SELECT id,title,text,(SELECT group_concat(tag,' ') FROM note_tags WHERE note_id=notes.id) FROM notes; COMMIT;" $null $bodyFile
      Send $ctx 200 'text/plain' 'ok'
    }
    elseif ($method -eq 'GET' -and $path -eq '/api/legacy') {
      # Old notes.json (pre-database) offered once to the page for import
      $done = Run-Sql "SELECT count(*) FROM meta WHERE key='legacyDone';"
      if ((Test-Path $legacy) -and $done -eq '0') { SendJson $ctx ([IO.File]::ReadAllText($legacy, $utf8)) } else { SendJson $ctx '{}' }
    }
    elseif ($method -eq 'POST' -and $path -eq '/api/legacy/done') {
      if ($ctx.Request.ContentType -notlike 'application/json*') { throw 'JSON only' }
      $null = Run-Sql "INSERT OR REPLACE INTO meta(key,value) VALUES('legacyDone','true');"
      if (Test-Path $legacy) { Move-Item $legacy "$legacy.bak" -Force }
      Send $ctx 200 'text/plain' 'ok'
    }
    else { Send $ctx 404 'text/plain' 'Not found' }
  }
  catch {
    Write-Host "Error on $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath): $_" -ForegroundColor Yellow
    try { Send $ctx 500 'text/plain' 'Server error' } catch {}
  }
  finally { if ($bodyFile) { Remove-Item $bodyFile -ErrorAction SilentlyContinue } }
}
