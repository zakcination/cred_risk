import zipfile,re,sys
import xml.etree.ElementTree as ET
M='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
p="/root/.claude/uploads/9f1a4a52-6f3b-5013-8235-26597383b957/e82a5269-____________________________________50_01.07.2026_______.xlsx"
z=zipfile.ZipFile(p)
sst=[]
if "xl/sharedStrings.xml" in z.namelist():
    r=ET.fromstring(z.read("xl/sharedStrings.xml").decode())
    for si in r.iter(M+'si'):
        sst.append("".join(t.text or "" for t in si.iter(M+'t')))
def col(ref):
    c=re.match(r"([A-Z]+)",ref).group(1); n=0
    for ch in c: n=n*26+ord(ch)-64
    return n
def dump(sheet,name,maxrow=400):
    r=ET.fromstring(z.read(sheet).decode())
    out=[]
    for row in r.iter(M+'row'):
        cells={}
        for c in row.iter(M+'c'):
            t=c.get('t'); v=c.find(M+'v'); isel=c.find(M+'is')
            val=""
            if t=='s' and v is not None: val=sst[int(v.text)]
            elif isel is not None: val="".join(x.text or "" for x in isel.iter(M+'t'))
            elif v is not None: val=v.text
            if val not in ("",None): cells[col(c.get('r'))]=str(val)
        if cells:
            mx=max(cells)
            out.append("R%s| "%row.get('r')+" | ".join(cells.get(i,"") for i in range(1,mx+1)))
    print("========== SHEET %s (%s) rows=%d =========="%(name,sheet,len(out)))
    for l in out[:maxrow]: print(l[:300])
for s,n in [("xl/worksheets/sheet5.xml","50-4"),("xl/worksheets/sheet6.xml","Выводы")]:
    dump(s,n)
