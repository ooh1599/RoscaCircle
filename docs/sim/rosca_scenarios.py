# Reproduces the numbers in rosca-review-2 and rosca-review-9 (Fractions, no rounding). Run: python3 rosca_scenarios.py
from fractions import Fraction as F
N=10; C=F(100); phi=F(1,2); D=F(100)
def sim(stop_after, quit_pre=None, reserve=F(0), release=True, upfront_int=F(0)):
    """stop_after: {pos: rounds_paid} for members who received before stopping (defaulters).
       quit_pre: {pos: rounds_paid} members who stop before their turn (forfeit turn, round skipped)."""
    quit_pre=quit_pre or {}
    paid={i:F(0) for i in range(1,N+1)}; cash={i:F(0) for i in range(1,N+1)}
    hold={i:F(0) for i in range(1,N+1)}
    cov=F(0); declared=set(); pots={}
    for t in range(1,N+1):
        # declare defaults for those who stopped before round t
        for i,lim in list(stop_after.items()):
            if t>lim and i not in declared:
                declared.add(i)
                cov+=hold[i]+D+upfront_int*0  # collateral
                hold[i]=F(0)
        for i,lim in list(quit_pre.items()):
            if t>lim and i not in declared:
                declared.add(i); cov+=D   # forfeited deposit, holdback none
        payers=[i for i in range(1,N+1) if i not in declared]
        if t in quit_pre and t in declared: 
            # forfeited slot: skip round, refund
            continue
        for i in payers:
            paid[i]+=C
            if release and cash[i]>0 and t>i and i not in declared:
                rel=min(hold[i],phi*C); hold[i]-=rel; cash[i]+=rel
        collected=C*len(payers)
        # reserve counted once at first default
        # recipient
        rec=t
        if rec in declared and rec in stop_after:  # already received earlier? (stop_after members always received before stopping)
            continue
        # coverage share: distribute cov over remaining unreceived recipients (including this one)
        rem=[j for j in range(t,N+1) if j not in declared and j not in quit_pre or (j in quit_pre and quit_pre[j]>=j)]
        share=(cov+reserve)/len(rem) if declared and rem else F(0)
        if declared: reserve=reserve  # keep
        # consume this round's share
        if declared:
            cov_used=share if cov>0 else F(0)
        h=phi*C*(N-t) if rec in payers else F(0)
        pot=collected
        if declared:
            take=min(cov+reserve, share); 
            pot+=take
            # reduce cov then reserve
            use_c=min(cov,take); cov-=use_c; reserve-= (take-use_c)
        cash[rec]+=pot-h; hold[rec]+=h
        pots[t]=pot
    return paid,cash,hold,pots
def net(paid,cash,hold,i): return cash[i]+hold[i]-paid[i]
# S1: pos1 pays round 1 only
p,c,h,pots=sim({1:1})
print("S1 victims net", [float(net(p,c,h,i)) for i in range(2,11)])
print("S1 total loss", float(-sum(net(p,c,h,i) for i in range(2,11))))
# S2: 1,2,3 stop after round 3
p,c,h,pots=sim({1:3,2:3,3:3})
v=[net(p,c,h,i) for i in range(4,11)]
print("S2 victims net", [float(x) for x in v], "total", float(-sum(v)))
# S3 with reserve 60 (distribute)
p,c,h,pots=sim({1:3,2:3,3:3},reserve=F(60))
v=[net(p,c,h,i) for i in range(4,11)]
print("S3 total", float(-sum(v)), "per", float(-sum(v)/7))
# S2 without progressive release (old numbers)
p,c,h,pots=sim({1:3,2:3,3:3},release=False)
v=[net(p,c,h,i) for i in range(4,11)]
print("S2 no-release total", float(-sum(v)), "per", float(-sum(v)/7))
# S4: pos10 pays 5 rounds then stops pre-turn
p,c,h,pots=sim({},quit_pre={10:5})
print("S4 nets", {i: float(net(p,c,h,i)) for i in range(1,11)}, "sum", float(sum(net(p,c,h,i) for i in range(1,11))))

print("--- checks")
# default after paying round 2 (pos1): doc 5 says loss 300, 37.5 per victim
p,c,h,pots=sim({1:2})
v=[net(p,c,h,i) for i in range(3,11)]
print("pos1 stops after round2: victims", [float(x) for x in v][:2], "total", float(-sum(v)))
# phi sweep vs formula (1-phi)C - D/n  (n=9) for S1
import itertools
for phi_ in [F(3,10),F(1,2),F(7,10),F(9,10),F(1)]:
    globals()['phi']=phi_
    p,c,h,pots=sim({1:1})
    v=[net(p,c,h,i) for i in range(2,11)]
    tot=-sum(v); form=max(F(0),(1-phi_)*C*9-D)
    print("phi",float(phi_),"sim loss",float(tot),"formula",float(form), "cash m1 pos1", float(c[1]))
