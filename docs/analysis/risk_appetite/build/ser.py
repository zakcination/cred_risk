import zipfile,re
import xml.etree.ElementTree as ET
M='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
p="/root/.claude/uploads/9f1a4a52-6f3b-5013-8235-26597383b957/e82a5269-____________________________________50_01.07.2026_______.xlsx"
z=zipfile.ZipFile(p)
sst=[]
r=ET.fromstring(z.read("xl/sharedStrings.xml").decode())
for si in r.iter(M+'si'): sst.append("".join(t.text or "" for t in si.iter(M+'t')))
def col(ref):
    c=re.match(r"([A-Z]+)",ref).group(1); n=0
    for ch in c: n=n*26+ord(ch)-64
    return n
r=ET.fromstring(z.read("xl/worksheets/sheet6.xml").decode())
for row in r.iter(M+'row'):
    cells={}
    for c in row.iter(M+'c'):
        t=c.get('t'); v=c.find(M+'v')
        if t=='s' and v is not None: val=sst[int(v.text)]
        elif v is not None: val=v.text
        else: continue
        cells[col(c.get('r'))]=val
    if not cells: continue
    keys=sorted(k for k in cells if k>=11)
    if not keys: continue
    lab=cells.get(11) or cells.get(12) or ""
    if len(str(lab))>60: continue
    vals=[]
    for k in sorted(cells):
        if k<12: continue
        v=cells[k]
        try:
            f=float(v)
            vals.append(("%.4f"%(f*100)) if abs(f)<3 else ("%.1f"%f))
        except: vals.append(str(v)[:9])
    if vals: print("%-42s"%str(lab)[:42], " ".join("%9s"%x for x in vals))
