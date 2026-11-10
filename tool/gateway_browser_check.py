#!/usr/bin/env python3
"""Reticulum in a real browser through a gateway (portal/docs/plan-browser-reticulum.md):
headless Chromium loads rns.js (reticulum-dart tool/build_rns_js.sh), connects to
the gateway, resolves a station, opens the link, checks /xprs/prove and calls the API.

    tool/gateway_browser_check.py DIR_WITH_index.html_AND_rns.js wss://x3ptzm.xprs.dev/rns X3PTZM

index.html only needs <script src="rns.js"></script>.
"""
import sys,os,time,json,threading,http.server,functools
sys.path.insert(0,os.path.join(os.path.dirname(os.path.abspath(__file__)),'..','..','portal','test'))
from cdp import Cdp
D=sys.argv[1]; gw=sys.argv[2]; call=sys.argv[3]
srv=http.server.ThreadingHTTPServer(('127.0.0.1',9941),functools.partial(http.server.SimpleHTTPRequestHandler,directory=D))
threading.Thread(target=srv.serve_forever,daemon=True).start()
c=Cdp('/usr/bin/chromium','/tmp/rns-browser-prof'); c.attach()
c.load('http://127.0.0.1:9941/',ready="document.readyState==='complete'&&!!window.XprsRns")
def run(js,secs=60):
    c.eval("window.__r=undefined;window.__e=undefined;(%s).then(function(v){window.__r=v},function(e){window.__e=String(e)});1"%js)
    v=c.wait("window.__r!==undefined||window.__e!==undefined",secs)
    return c.eval("window.__e?('ERROR '+window.__e):window.__r")
t0=time.time()
print('connect:', run("XprsRns.connect(%r)"%gw), '%.2fs'%(time.time()-t0))
r=json.loads(run("XprsRns.resolve(%r)"%call)); print('resolve:', (r.get('rns') or 'none')[:16], 'identity' if r.get('identity') else 'no identity', '%.2fs'%(time.time()-t0))
print('open:', run("XprsRns.open(%r)"%r['rns']), '%.2fs'%(time.time()-t0))
p=json.loads(run("XprsRns.prove('n%d')"%int(time.time()*1000)))
print('prove:', 'names the link' if ('m:'+p['link']+'.') in (p.get('session') or '') else 'BAD', '%.2fs'%(time.time()-t0))
for path in ['/api/services','/api/xprs/history']:
    s=time.time()
    out=run("XprsRns.api('GET',%r,'{\"limit\":\"20\"}',null).then(function(r){return r.status+' '+r.type+' '+r.body.length+' '+new TextDecoder().decode(r.body).slice(0,80)})"%path)
    print(path+':', out, '%dms'%((time.time()-s)*1000))
c.close(); srv.shutdown()
