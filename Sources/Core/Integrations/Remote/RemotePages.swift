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
<div id="pin"><p id="pinmsg">Enter the remote PIN shown in Lumen → Setup → Remote &amp; MIDI.</p><input id="pinval" inputmode="numeric" placeholder="PIN"> <button onclick="savePin()">Connect</button></div>
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
let pin=localStorage.getItem('lumenPin')||'',locked=false,state=null,plSel=localStorage.getItem('lumenPl')||'',browsing=null;
const $=id=>document.getElementById(id);
// Everything from the show (song titles, lyrics, timer names) is untrusted text: build elements, never HTML strings.
function el(tag,props,...kids){const e=document.createElement(tag);for(const k in (props||{})){if(k==='class')e.className=props[k];else if(k==='style')e.style.cssText=props[k];else if(k.startsWith('on'))e.addEventListener(k.slice(2),props[k]);else e.setAttribute(k,props[k])}
 for(const c of kids.flat())e.append(c&&c.nodeType?c:document.createTextNode(c==null?'':String(c)));return e}
function fill(parent,...kids){parent.replaceChildren(...kids.flat())}
function lock(msg){locked=true;$('pin').style.display='block';$('app').style.display='none';document.querySelector('.bar').style.display='none';$('pinmsg').textContent=msg}
function unlock(){locked=false;$('pin').style.display='none';$('app').style.display='';document.querySelector('.bar').style.display=''}
function savePin(){pin=$('pinval').value;localStorage.setItem('lumenPin',pin);unlock();poll()}
async function api(path,opts={}){opts.headers=Object.assign({'X-Lumen-PIN':pin,'Content-Type':'application/json'},opts.headers||{});
 const r=await fetch(path,opts);if(r.status==401||r.status==429){lock(r.status==429?'Too many wrong PINs. Wait a minute, then enter the PIN again.':'Enter the remote PIN shown in Lumen → Setup → Remote & MIDI.');throw 'pin'}if(locked)unlock();return r.json()}
async function cmd(b){if(locked)return;try{await api('/api/cmd',{method:'POST',body:JSON.stringify(b)});poll()}catch(e){}}
function slides(box,list,id,liveIdx,plid){fill(box,list.map((s,i)=>el('button',{class:'slide'+(i==liveIdx?' live':''),onclick:()=>cmd({cmd:'trigger',id:id,index:i,playlist:plid||''})},
 el('span',{class:'g',style:'color:'+(/^#[0-9a-fA-F]{3,8}$/.test(s.color)?s.color:'#888')},s.group),s.text)))}
async function openPres(id,name){browsing=await api('/api/presentation?id='+encodeURIComponent(id));$('browseSec').style.display='';$('browseTitle').textContent=name;render();$('browseSec').scrollIntoView({behavior:'smooth'})}
function render(){if(!state)return;const L=state.live;$('title').textContent=L.name||'Lumen';
 slides($('live'),L.slides||[],L.id,L.cleared?-1:L.index,'');
 fill($('look'),state.looks.map(l=>el('option',{value:l.id,selected:l.id==state.lookID?'':null},l.name)));
 fill($('macros'),state.macros.map(m=>el('button',{style:'border-color:'+(/^#[0-9a-fA-F]{3,8}$/.test(m.color)?m.color:'#888'),onclick:()=>cmd({cmd:'macro',id:m.id})},m.name)));
 fill($('props'),state.props.map(p=>el('button',{class:p.active?'on':'',onclick:()=>cmd({cmd:'prop',id:p.id})},p.name)));
 fill($('timers'),state.timers.map(t=>el('div',{class:'row',style:'align-items:center;margin-bottom:6px'},el('span',{style:'flex:2'},t.name),el('b',{style:'flex:1;font-variant-numeric:tabular-nums'},t.value),
   el('button',{onclick:()=>cmd({cmd:'timer',id:t.id,action:t.running?'stop':'start'})},t.running?'Stop':'Start'),el('button',{onclick:()=>cmd({cmd:'timer',id:t.id,action:'reset'})},'Reset'))));
 if(!plSel&&state.playlists.length)plSel=state.playlists[0].id;
 fill($('pl'),state.playlists.map(p=>el('option',{value:p.id,selected:p.id==plSel?'':null},p.name)));
 const pl=state.playlists.find(p=>p.id==plSel);
 fill($('items'),pl?pl.items.map(it=>it.type=='header'?el('div',{class:'hdr'},it.name):it.type=='placeholder'?el('button',{class:'ph',disabled:''},it.name)
   :el('button',{onclick:()=>openPres(it.id,it.name)},it.name,it.id==L.id?el('span',{class:'tag',style:'background:#ef4444;margin-left:8px'},'LIVE'):'')):[]);
 if(browsing)slides($('browse'),browsing.slides,browsing.id,browsing.id==L.id&&!L.cleared?L.index:-1,plSel);
}
$('look').onchange=e=>cmd({cmd:'look',id:e.target.value});
$('pl').onchange=e=>{plSel=e.target.value;localStorage.setItem('lumenPl',plSel);render()};
async function poll(){if(locked)return;try{state=await api('/api/state');render()}catch(e){}}
setInterval(poll,700);poll();
document.addEventListener('keydown',e=>{if(e.target.tagName=='INPUT'||e.repeat)return;if(e.key=='ArrowRight'||e.key==' ')cmd({cmd:'next'});if(e.key=='ArrowLeft')cmd({cmd:'prev'})});
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
const el=(t,p,...k)=>{const e=document.createElement(t);for(const x in (p||{})){if(x==='style')e.style.cssText=p[x];else e.setAttribute(x,p[x])}for(const c of k.flat())e.append(c&&c.nodeType?c:document.createTextNode(c==null?'':String(c)));return e};
const chordHTML=ls=>el('div',{},ls.map(l=>el('span',{class:'cl'},l.map(g=>el('span',{class:'sg'},el('b',{},(g.c||'')+(g.c?'\u00a0':'')),g.t||'\u00a0')))));
if(s.currentChords&&s.currentChords.length){$('cur').replaceChildren(chordHTML(s.currentChords))}else{$('cur').textContent=s.current||''}
if(s.nextChordLines&&s.nextChordLines.length){$('nextt').replaceChildren(chordHTML(s.nextChordLines))}else{$('nextt').textContent=s.next||'—'}
if(s.key)$('ng').textContent+=' · KEY '+s.key;
$('ng').textContent=s.nextGroup?'NEXT • '+s.nextGroup.toUpperCase():'NEXT';$('notes').textContent=s.notes||'';
$('msg').style.display=s.message?'block':'none';$('msg').textContent=s.message||'';
$('timers').replaceChildren(...(s.timers||[]).map(t=>el('div',{class:'t'},el('small',{},t.name),el('b',{style:'color:'+(String(t.value).startsWith('-')?'#ef4444':'#fff')},t.value))))}catch(e){}}
setInterval(poll,400);poll();
</script></body></html>
"""#
}
