#!/usr/bin/env python3
"""Inventory Swift string literals without treating comments or interpolation as UI text."""
import re,json,pathlib,sys,textwrap
HAN=re.compile('[\u3400-\u9fff]')
records={}
def string(s,i):
    start=i; raw=0
    while i<len(s) and s[i]=='#':raw+=1;i+=1
    if i>=len(s) or s[i]!='"':return None
    triple=s.startswith('"""',i);quote='"""' if triple else '"';i+=len(quote)
    parts=[];args=[];buf='';close=quote+'#'*raw;esc='\\'+'#'*raw
    while i<len(s):
        if s.startswith(close,i):
            parts.append(buf);return i+len(close),parts,args,raw,triple
        if s.startswith(esc+'(',i):
            parts.append(buf);buf='';j=i+len(esc)+1;level=1;k=j
            while k<len(s) and level:
                st=string(s,k) if s[k] in '"#' else None
                if st:k=st[0];continue
                if s[k]=='(':level+=1
                elif s[k]==')':level-=1
                k+=1
            args.append(s[j:k-1]);i=k;continue
        if s.startswith(esc,i) and i+len(esc)<len(s):
            # Preserve escaped quotation marks instead of interpreting as terminators.
            buf+=s[i:i+len(esc)+1];i+=len(esc)+1;continue
        buf+=s[i];i+=1
    raise ValueError(('unterminated string',s[start:start+80]))
def decoded(s,raw):
    if raw:return s
    s=re.sub(r'\\u\{([0-9a-fA-F]+)\}',lambda m:chr(int(m[1],16)),s)
    return re.sub(r'\\([nrt0"\\])',lambda m:{'n':'\n','r':'\r','t':'\t','0':'\0','"':'"','\\':'\\'}[m[1]],s)
def process(s,path,apply=False):
    i=0;out=''
    while i<len(s):
        if s.startswith('//',i):
            j=s.find('\n',i);j=len(s) if j<0 else j;out+=s[i:j];i=j;continue
        if s.startswith('/*',i):
            j=i+2;depth=1
            while j<len(s) and depth:
                if s.startswith('/*',j):depth+=1;j+=2
                elif s.startswith('*/',j):depth-=1;j+=2
                else:j+=1
            out+=s[i:j];i=j;continue
        st=string(s,i) if s[i] in '"#' else None
        if not st:out+=s[i];i+=1;continue
        end,parts,args,raw,triple=st
        prefix=s[s.rfind('\n',0,i)+1:i]
        key=''.join(decoded(t,raw)+(('{'+str(n)+'}') if n<len(args) else '') for n,t in enumerate(parts))
        if triple:key=textwrap.dedent(key).strip('\n ')
        if HAN.search(key) and not prefix.rstrip().endswith('AppLanguage.text(') and not re.search(r'\b(logger|log)\.(debug|info|notice|warning|error|fault)\s*\(',prefix):
            records.setdefault(key,[]).append({'file':str(path),'line':s.count('\n',0,i)+1,'raw':bool(raw),'multiline':triple})
            if apply:
                arguments=[process(a,path,apply=True) for a in args]
                out+='AppLanguage.text('+json.dumps(key,ensure_ascii=False)+''.join(', String(describing: ('+a+'))' for a in arguments)+')'
            else:out+=s[i:end]
        else:
            nested=[process(a,path,apply) for a in args]
            if apply and args:
                quote='"""' if triple else '"'
                out+='#'*raw+quote+''.join(t+((('\\'+'#'*raw+'(')+nested[n]+')') if n<len(nested) else '') for n,t in enumerate(parts))+quote+'#'*raw
            else:out+=s[i:end]
        i=end
    return out
if __name__=='__main__':
    apply='--apply' in sys.argv
    for path in sorted(pathlib.Path('Sources').rglob('*.swift')):
        s=path.read_text();n=process(s,path,apply)
        if apply and n!=s:
            if '/MacOSX/' in str(path) and 'import MacOSXCore' not in n:n='import MacOSXCore\n'+n
            path.write_text(n)
    pathlib.Path('Resources/Localization/inventory.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n')
    print(len(records),'unique strings',sum(len(v) for v in records.values()),'occurrences')
