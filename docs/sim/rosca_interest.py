# Reproduces the interest table in rosca-review-9 section 3.2. Run: python3 rosca_interest.py
from fractions import Fraction as F
N=10; C=F(100); phi=F(1,2); D=F(100); r=F(1,100)

def run(defaults=None, quit_pre=None, upfront=False, interest=True, verbose=False):
    """defaults: {pos: last_round_paid} (member stops after paying that many rounds, after receiving)
       quit_pre: {pos: last_round_paid} member stops BEFORE their turn (forfeits)"""
    defaults=defaults or {}; quit_pre=quit_pre or {}
    paid={i:F(0) for i in range(1,N+1)}; cash={i:F(0) for i in range(1,N+1)}
    hold={i:F(0) for i in range(1,N+1)}; dep={i:D for i in range(1,N+1)}
    intpaid={i:F(0) for i in range(1,N+1)}; intget={i:F(0) for i in range(1,N+1)}
    stopped=set(); defaulted_unrecovered=F(0)
    victims_net={}
    cov_pool=F(0)
    debt_prev={}; credit_prev={}
    pots={}
    for t in range(1,N+1):
        # who pays this round
        payers=[]
        for i in range(1,N+1):
            lim=defaults.get(i, quit_pre.get(i, 99))
            if i in stopped: continue
            if t>lim: stopped.add(i); continue
            payers.append(i)
        # interest for this round based on prev positions (pay-as-you-go)
        pool=F(0)
        if interest and not upfront and t>1:
            for i in payers:
                L=cash[i]-paid[i]
                if L>0:
                    x=r*L; intpaid[i]+=x; pool+=x
            K={j:paid[j]-cash[j] for j in range(1,N+1) if paid[j]-cash[j]>0}
            tk=sum(K.values())
            if tk>0 and pool>0:
                for j,k in K.items(): intget[j]+=pool*k/tk
        # installments
        for i in payers:
            paid[i]+=C
            # release holdback for installments after receipt, only if own funds
            if cash[i]>0 and t>i: 
                rel=min(hold[i],phi*C); hold[i]-=rel; cash[i]+=rel
        collected=C*len(payers)
        rec=t
        if rec in quit_pre and t>quit_pre[rec]:   # recipient forfeited -> skip round, refund
            for i in payers: paid[i]-=C
            pots[t]=None
            continue
        # recipient
        h=phi*C*(N-t) if rec in payers else F(0)
        if rec in stopped or rec not in payers:
            # defaulted debtor? recipient already got paid earlier; if rec in defaults they received already
            pass
        if rec in payers or rec not in defaults:
            pot=collected
            pot+= cov_pool   # coverage from defaulters distributed (computed lazily below)
            payout=pot-h
            hold[rec]+=h
            cash[rec]+=payout
            pots[t]=pot
    return paid,cash,hold,dep,intpaid,intget,pots

# --- no-default baseline: interest table
paid,cash,hold,dep,ip,ig,pots=run()
print("baseline interest paid/get/net")
for i in range(1,N+1): print(i,float(ip[i]),float(ig[i]),float(ig[i]-ip[i]))
print("tot paid",float(sum(ip.values())),"tot get",float(sum(ig.values())))
# end-of-group check: net money per member (cash + hold - paid) should be ~0 with interest excluded
print("net no interest", [float(cash[i]+hold[i]-paid[i]) for i in range(1,N+1)])
