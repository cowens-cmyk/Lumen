import Foundation

/// Self-contained pages served to phones, tablets and laptops on the same network.
enum RemotePages {
    static let remote = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Lumen Remote</title>
<style>
:root{--bg:#0b0d12;--panel:#151922;--line:#262c38;--text:#e8ebf1;--muted:#8a93a5;--accent:#f59e0b;--live:#ef4444}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px -apple-system,system-ui,sans-serif;padding-bottom:110px}
header{position:sticky;top:0;background:rgba(11,13,18,.95);backdrop-filter:blur(8px);padding:12px 16px;border-bottom:1px solid var(--line);z-index:5;display:flex;gap:8px;align-items:center}
header h1{font-size:17px;margin:0;flex:1}select,input,button{font:inherit;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:10px 12px}
button{cursor:pointer}button:active{transform:scale(.97)}
.section{padding:12px 16px}.section h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin:8px 0}
.row{display:flex;gap:8px;flex-wrap:wrap}.row button{flex:1 1 auto}
.items button{display:block;width:100%;text-align:left;margin-bottom:6px}
.items .hdr{color:var(--muted);font-size:12px;text-transform:uppercase;margin:14px 0 6px}
.items .ph{opacity:.5}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px}
.slide{background:var(--panel);border:2px solid var(--line);border-radius:10px;padding:8px;min-height:90px;text-align:left;white-space:pre-wrap;font-size:13px;position:relative}
.slide .g{font-size:10px;font-weight:700;text-transform:uppercase;display:block;margin-bottom:4px}
.slide.live{border-color:var(--live);box-shadow:0 0 0 2px var(--live)}
.bar{position:fixed;left:0;right:0;bottom:0;background:var(--panel);border-top:1px solid var(--line);padding:12px 16px calc(12px + env(safe-area-inset-bottom));display:flex;gap:10px}
.bar button{flex:1;font-size:20px;font-weight:700;padding:16px}
.bar .next{background:var(--accent);color:#111;border:none}
#pin{display:none;padding:40px 16px;text-align:center}
.tag{font-size:11px;padding:2px 6px;border-radius:6px;background:var(--line)}
.on{background:var(--accent)!important;color:#111!important}
</style></head><body>
<header><h1 id="title">Lumen</h1><select id="look" title="Look"></select></header>
<div id="pin"><p>Enter the remote PIN shown in Lumen → Settings → Remote.</p><input id="pinval" inputmode="numeric" placeholder="PIN"> <button onclick="savePin()">Connect</button></div>
<div id="app">
 <div class="section"><h2>Live</h2><div id="live" class="grid"></div></div>
 <div class="section"><h2>Clear</h2><div class="row">
  <button onclick="cmd({cmd:'clear',target:'slide'})">Slide</button><button onclick="cmd({cmd:'clear',target:'media'})">Media</button>
  <button onclick="cmd({cmd:'clear',target:'props'})">Props</button><button onclick="cmd({cmd:'clear',target:'all'})" style="color:#f87171">All</button></div></div>
 <div class="section"><h2>Macros</h2><div id="macros" class="row"></div></div>
 <div class="section"><h2>Props / Lower Thirds</h2><div id="props" class="row"></div></div>
 <div class="section"><h2>Timers</h2><div id="timers"></div></div>
 <div class="section"><h2>Message</h2><div class="row"><input id="msg" placeholder="Audience message" style="flex:3"><button onclick="cmd({cmd:'message',text:msg.value})">Show</button><button onclick="cmd({cmd:'message',text:''})">Hide</button></div>
  <div class="row" style="margin-top:8px"><input id="smsg" placeholder="Stage message" style="flex:3"><button onclick="cmd({cmd:'stageMessage',text:smsg.value})">Stage</button><button onclick="cmd({cmd:'stageMessage',text:''})">Hide</button></div></div>
 <div class="section"><h2>Playlist</h2><select id="pl" style="width:100%;margin-bottom:8px"></select><div id="items" class="items"></div></div>
 <div class="section" id="browseSec" style="display:none"><h2 id="browseTitle"></h2><div id="browse" class="grid"></div></div>
</div>
<div class="bar"><button onclick="cmd({cmd:'prev'})">◀ Prev</button><button class="next" onclick="cmd({cmd:'next'})">Next ▶</button></div>
<script>
let pin=localStorage.getItem('lumenPin')||'',state=null,plSel=localStorage.getItem('lumenPl')||'',browsing=null;
const $=id=>document.getElementById(id);
function savePin(){pin=$('pinval').value;localStorage.setItem('lumenPin',pin);$('pin').style.display='none';$('app').style.display='';poll()}
async function api(path,opts={}){opts.headers=Object.assign({'X-Lumen-PIN':pin,'Content-Type':'application/json'},opts.headers||{});
 const r=await fetch(path,opts);if(r.status==401){$('pin').style.display='block';$('app').style.display='none';throw 'pin'}return r.json()}
async function cmd(b){try{await api('/api/cmd',{method:'POST',body:JSON.stringify(b)});poll()}catch(e){}}
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function slides(el,list,id,liveIdx,plid){el.innerHTML=list.map((s,i)=>`<button class="slide ${i==liveIdx?'live':''}" onclick="cmd({cmd:'trigger',id:'${id}',index:${i},playlist:'${plid||''}'})"><span class="g" style="color:${s.color}">${esc(s.group)}</span>${esc(s.text)}</button>`).join('')}
async function openPres(id,name){browsing=await api('/api/presentation?id='+id);$('browseSec').style.display='';$('browseTitle').textContent=name;render();$('browseSec').scrollIntoView({behavior:'smooth'})}
function render(){if(!state)return;const L=state.live;$('title').textContent=L.name||'Lumen';
 slides($('live'),L.slides||[],L.id,L.cleared?-1:L.index,'');
 $('look').innerHTML=state.looks.map(l=>`<option value="${l.id}" ${l.id==state.lookID?'selected':''}>${esc(l.name)}</option>`).join('');
 $('macros').innerHTML=state.macros.map(m=>`<button style="border-color:${m.color}" onclick="cmd({cmd:'macro',id:'${m.id}'})">${esc(m.name)}</button>`).join('');
 $('props').innerHTML=state.props.map(p=>`<button class="${p.active?'on':''}" onclick="cmd({cmd:'prop',id:'${p.id}'})">${esc(p.name)}</button>`).join('');
 $('timers').innerHTML=state.timers.map(t=>`<div class="row" style="align-items:center;margin-bottom:6px"><span style="flex:2">${esc(t.name)}</span><b style="flex:1;font-variant-numeric:tabular-nums">${t.value}</b><button onclick="cmd({cmd:'timer',id:'${t.id}',action:'${t.running?'stop':'start'}'})">${t.running?'Stop':'Start'}</button><button onclick="cmd({cmd:'timer',id:'${t.id}',action:'reset'})">Reset</button></div>`).join('');
 if(!plSel&&state.playlists.length)plSel=state.playlists[0].id;
 $('pl').innerHTML=state.playlists.map(p=>`<option value="${p.id}" ${p.id==plSel?'selected':''}>${esc(p.name)}</option>`).join('');
 const pl=state.playlists.find(p=>p.id==plSel);
 $('items').innerHTML=pl?pl.items.map(it=>it.type=='header'?`<div class="hdr">${esc(it.name)}</div>`:it.type=='placeholder'?`<button class="ph" disabled>${esc(it.name)}</button>`:`<button onclick="openPres('${it.id}','${esc(it.name).replace(/'/g,"")}')">${esc(it.name)} ${it.id==L.id?'<span class="tag" style="background:#ef4444">LIVE</span>':''}</button>`).join(''):'';
 if(browsing)slides($('browse'),browsing.slides,browsing.id,browsing.id==L.id&&!L.cleared?L.index:-1,plSel);
}
$('look').onchange=e=>cmd({cmd:'look',id:e.target.value});
$('pl').onchange=e=>{plSel=e.target.value;localStorage.setItem('lumenPl',plSel);render()};
async function poll(){try{state=await api('/api/state');render()}catch(e){}}
setInterval(poll,700);poll();
document.addEventListener('keydown',e=>{if(e.target.tagName=='INPUT')return;if(e.key=='ArrowRight'||e.key==' ')cmd({cmd:'next'});if(e.key=='ArrowLeft')cmd({cmd:'prev'})});
</script></body></html>
"""#

    static let stage = #"""
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lumen Stage</title>
<style>
html,body{margin:0;height:100%;background:#000;color:#fff;font-family:-apple-system,system-ui,sans-serif;overflow:hidden}
#wrap{display:flex;flex-direction:column;height:100%}
#top{display:flex;justify-content:space-between;padding:2vh 3vw;font-variant-numeric:tabular-nums}
#clock{font-size:6vh;font-weight:800}#timers{display:flex;gap:4vw}.t{text-align:right}.t small{display:block;color:#888;font-size:2vh;font-weight:700;text-transform:uppercase}.t b{font-size:6vh}
#msg{align-self:center;background:#facc15;color:#000;font-weight:800;font-size:5vh;padding:1vh 2vw;border-radius:1vh;display:none}
#cur{flex:1;display:flex;align-items:center;justify-content:center;text-align:center;font-weight:800;font-size:8vh;padding:0 4vw;white-space:pre-wrap;line-height:1.15}
#notes{color:#67e8f9;font-size:4vh;padding:0 4vw}
#next{background:#161616;padding:2vh 4vw}
.cl{display:block;white-space:nowrap}.sg{display:inline-flex;flex-direction:column;white-space:pre}.sg b{color:#38bdf8;font-size:.6em;font-weight:900;min-height:1.1em}#next small{color:#888;font-weight:800;font-size:2.2vh}#nextt{color:#facc15;font-size:5vh;font-weight:600;white-space:pre-wrap}
</style></head><body><div id="wrap">
<div id="top"><div id="clock"></div><div id="timers"></div></div><div id="msg"></div>
<div id="cur"></div><div id="notes"></div><div id="next"><small id="ng">NEXT</small><div id="nextt"></div></div></div>
<script>
const $=id=>document.getElementById(id);
async function poll(){try{const s=await (await fetch('/api/stage')).json();
$('clock').textContent=s.clock||'';
const esc=x=>(x||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
const chordHTML=ls=>'<div>'+ls.map(l=>'<span class="cl">'+l.map(g=>`<span class="sg"><b>${esc(g.c)}${g.c?'&nbsp;':''}</b>${esc(g.t)||'&nbsp;'}</span>`).join('')+'</span>').join('')+'</div>';
if(s.currentChords&&s.currentChords.length){$('cur').innerHTML=chordHTML(s.currentChords)}else{$('cur').textContent=s.current||''}
if(s.nextChordLines&&s.nextChordLines.length){$('nextt').innerHTML=chordHTML(s.nextChordLines)}else{$('nextt').textContent=s.next||'—'}
if(s.key)$('ng').textContent+=' · KEY '+s.key;
$('ng').textContent=s.nextGroup?'NEXT • '+s.nextGroup.toUpperCase():'NEXT';$('notes').textContent=s.notes||'';
$('msg').style.display=s.message?'block':'none';$('msg').textContent=s.message||'';
$('timers').innerHTML=(s.timers||[]).map(t=>`<div class="t"><small>${t.name}</small><b style="color:${t.value.startsWith('-')?'#ef4444':'#fff'}">${t.value}</b></div>`).join('')}catch(e){}}
setInterval(poll,400);poll();
</script></body></html>
"""#
}
