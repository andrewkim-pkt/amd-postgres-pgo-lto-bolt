#!/bin/bash
# g15m whole-box ladder report (CLIENT). Per rung: NOPM, busy % over the MEASURED window ("Rampup complete" ..
# "System achieved") for the whole box, each NUMA node, and the client. Per pass: placement (datadir tmpfs pages per
# node = Shmem after restore minus the golden-only baseline; mysqld pages per node from numastat -p). Then the tables.
# Passes: tags 01-04 = A, 05-08 = B (mirrored).
B=${1:-/home/ec2-user/g15m/wb}
N0="0-95"; N1="96-191"   # AMD r8a.metal-48xl: 2 NUMA nodes, 192 cores, no SMT
busy() { # file s e set ("all" = aggregate cpu line, else cpu list a-b,c-d)
  awk -v s=$2 -v e=$3 -v m=$4 '
   BEGIN{ if(m!="all"){ n=split(m,R,","); for(i=1;i<=n;i++){ split(R[i],x,"-"); lo[i]=x[1]; hi[i]=x[2] } } }
   function inset(c,  k,j){ if(m=="all") return c=="cpu"; if(c=="cpu") return 0; k=substr(c,4)+0
     for(j=1;j<=n;j++) if(k>=lo[j]&&k<=hi[j]) return 1; return 0 }
   { t=$1; if(t<s||t>e) next; if(!inset($2)) next
     tot=$3+$4+$5+$6+$7+$8+$9+$10; idl=$6+$7
     if(!(t in T)){ T[t]=0; I[t]=0; ts[++k]=t }
     T[t]+=tot; I[t]+=idl }
   END{ if(k<2){print "-1";exit}; a=ts[1]; b=ts[k]; dt=T[b]-T[a]; di=I[b]-I[a]; printf "%.1f", 100*(dt-di)/dt }' $1; }
echo "## per rung"
printf "%-12s %5s %10s %6s %6s %6s %6s\n" tag VU NOPM box% n0% n1% cli%
for f in $(ls $B/[0-9][0-9]-*-*.txt 2>/dev/null | sort -t- -k1,1 -k3,3n); do
  base=$(basename $f .txt); vu=${base##*-}; tag=${base%-*}
  st=$(tr -d '\r' < $f | grep -a -m1 'Rampup complete' | awk '{print $1}')
  en=$(tr -d '\r' < $f | grep -a -m1 'System achieved' | awk '{print $1}')
  nopm=$(tr -d '\r' < $f | grep -a -m1 'System achieved' | grep -oE 'achieved [0-9]+' | awk '{print $2}')
  [ -n "$st" ] && [ -n "$en" ] && [ -f $B/$tag.cpu ] || { printf "%-12s %5s %10s\n" $tag $vu "${nopm:-FAILED}"; continue; }
  s=$(date -u -d "$st" +%s); e=$(date -u -d "$en" +%s)
  printf "%-12s %5s %10s %6s %6s %6s %6s\n" $tag $vu $nopm $(busy $B/$tag.cpu $s $e all) $(busy $B/$tag.cpu $s $e $N0) $(busy $B/$tag.cpu $s $e $N1) $(busy $B/$tag.clicpu $s $e all)
done | tee $B/points.txt
echo
echo "## placement per pass (MB per node; skew = max/min; flagged if > 1.10)"
printf "%-12s %-30s %6s   %-30s %6s\n" tag "datadir tmpfs n0/n1" skew "mysqld n0/n1 (end)" skew
for r in $(ls $B/[0-9][0-9]-*.numa-restore 2>/dev/null | sort); do
  tag=$(basename $r .numa-restore)
  d=$(awk 'FNR==NR{ if($1=="Shmem") for(i=2;i<=3;i++) g[i]=$i; next } $1=="Shmem"{ printf "%.0f %.0f", $2-g[2], $3-g[3] }' $B/numa-golden-baseline $r)
  p=$( [ -f $B/$tag.numa-proc ] && awk '$1=="Total"{ printf "%.0f %.0f", $2, $3 }' $B/$tag.numa-proc )
  sk() { echo "$1" | awk 'NF==2{mx=$1;mn=$1; if($2>mx)mx=$2; if($2<mn)mn=$2; printf "%.3f%s", (mn>0?mx/mn:99), (mn>0&&mx/mn<=1.10?"":" !!") }'; }
  printf "%-12s %-30s %6s   %-30s %6s\n" $tag "$(echo $d | tr ' ' /)" "$(sk "$d")" "$(echo $p | tr ' ' /)" "$(sk "$p")"
done | tee $B/placement.txt
echo
awk '$1 ~ /^[0-9]/ && $3 ~ /^[0-9]+$/ { split($1,x,"-"); arm=x[2]; p=(x[1]+0<=4)?"A":"B"; v=$2; k=arm","v
      N[k]+=$3; C[k]++; U[k]+=$4; P[k","p]=$3; V[v]=1 }
 END{ split("base afdoltob pgolto pgoltob",A," "); nv=split("32 64 128 256 512 1024",VU," ")
  h="| arm |"; s="|---|"; for(j=1;j<=nv;j++){ h=h " " VU[j] " vu nopm (vs base) |"; s=s "---:|" }
  print h " mean gain | CPU/txn vs base (mean of rungs) |"; print s "---:|---:|"
  for(i=1;i<=4;i++){ a=A[i]; line="| " a; g=0; ng=0; ct=0; nc=0
    for(j=1;j<=nv;j++){ v=VU[j]; k=a","v; kb="base,"v
      if(!C[k]||!C[kb]){ line=line " | -"; continue }
      n=N[k]/C[k]; nb=N[kb]/C[kb]; d=(n-nb)*100/nb; g+=d; ng++
      cpt=(U[k]/C[k])/n; cptb=(U[kb]/C[kb])/nb; ct+=(cpt-cptb)*100/cptb; nc++
      line=line sprintf(" | %\047d (%+.2f%%)", n, d) }
    print line sprintf(" | %+.2f%% | %+.1f%% |", (ng?g/ng:0), (nc?ct/nc:0)) }
  print ""; print "CPU/txn per rung (box busy % / NOPM, vs base):"
  for(i=2;i<=4;i++){ a=A[i]; line=sprintf("  %-9s", a)
    for(j=1;j<=nv;j++){ v=VU[j]; k=a","v; kb="base,"v; if(!C[k]||!C[kb]){ line=line "     -"; continue }
      line=line sprintf(" %4s:%+.1f%%", v, ((U[k]/C[k])/(N[k]/C[k]) - (U[kb]/C[kb])/(N[kb]/C[kb]))*100/((U[kb]/C[kb])/(N[kb]/C[kb]))) }
    print line }
  print ""; print "per pass NOPM (A / B, spread = |A-B|/mean):"
  for(i=1;i<=4;i++){ a=A[i]; line=sprintf("  %-9s", a)
    for(j=1;j<=nv;j++){ v=VU[j]; pa=P[a","v",A"]; pb=P[a","v",B"]
      if(pa==""||pb==""){ line=line sprintf(" %s: %s/%s", v, (pa==""?"-":pa), (pb==""?"-":pb)); continue }
      line=line sprintf(" %s: %d/%d (%.1f%%)", v, pa, pb, 200*(pa>pb?pa-pb:pb-pa)/(pa+pb)) }
    print line } }' $B/points.txt
