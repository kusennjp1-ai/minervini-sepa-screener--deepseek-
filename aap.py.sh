cat > app.py << 'ENDOFFILE'
"""
Mark Minervini SEPA Screener - 完全無料版
"""
import streamlit as st
import pandas as pd
import numpy as np
import yfinance as yf
import plotly.graph_objects as go
from plotly.subplots import make_subplots
from datetime import datetime

st.set_page_config(page_title="SEPA Screener", page_icon="📈", layout="wide")

# ==================== キャッシュ ====================
@st.cache_data(ttl=3600)
def download_data(ticker, period='2y'):
    try:
        return yf.download(ticker, period=period, progress=False)
    except:
        return pd.DataFrame()

@st.cache_data(ttl=86400)
def get_sp500_list():
    try:
        url = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"
        return pd.read_html(url)[0]['Symbol'].str.replace('.', '-', regex=False).tolist()
    except:
        return ['AAPL','MSFT','AMZN','NVDA','GOOGL','META','TSLA','AVGO','COST','NFLX',
                'AMD','ADBE','CRM','QCOM','TXN','INTU','AMAT','MU','ADI','LRCX',
                'INTC','PYPL','BKNG','ISRG','REGN','VRTX','GILD','AMGN','PANW']

@st.cache_data(ttl=3600)
def get_industry(ticker):
    try:
        info = yf.Ticker(ticker).info
        return info.get('sector','Unknown'), info.get('industry','Unknown')
    except:
        return 'Unknown','Unknown'

# ==================== Market 360 ====================
def evaluate_market_360():
    try:
        sp500 = yf.download('^GSPC', period='1y', progress=False)
        vix = yf.download('^VIX', period='1mo', progress=False)
        if sp500.empty: return 'UPTREND_UNDER_PRESSURE', 55, {}
        details, score = {}, 0
        sp500['SMA50'] = sp500['Close'].rolling(50).mean()
        sp500['SMA150'] = sp500['Close'].rolling(150).mean()
        sp500['SMA200'] = sp500['Close'].rolling(200).mean()
        latest = sp500.iloc[-1]
        if (latest['Close'] > latest['SMA50'] > latest['SMA150'] > latest['SMA200']).all():
            score += 25; details['トレンド'] = '完全強気'
        elif latest['Close'] > latest['SMA200']:
            score += 15; details['トレンド'] = '長期線上'
        else:
            details['トレンド'] = '弱気'
        sma50_up = sp500['SMA50'].diff(5).iloc[-1] > 0 if len(sp500)>5 else False
        sma150_up = sp500['SMA150'].diff(5).iloc[-1] > 0 if len(sp500)>150 else False
        sma200_up = sp500['SMA200'].diff(5).iloc[-1] > 0 if len(sp500)>200 else False
        if sma50_up and sma150_up: score += 10
        if sma200_up: score += 5
        details['MA'] = f'50:{sma50_up} 150:{sma150_up} 200:{sma200_up}'
        if not vix.empty:
            v = vix['Close'].iloc[-1]; details['VIX'] = f'{v:.1f}'
            score += 10 if v<20 else (5 if v<30 else -5)
        h52 = sp500['High'].rolling(252).max().iloc[-1]
        if not pd.isna(h52):
            dd = latest['Close']/h52; details['高値距離'] = f'{dd*100:.1f}%'
            score += 10 if dd>0.9 else (5 if dd>0.8 else 0)
        score = max(0,min(100,score))
        mode = 'CONFIRMED_UPTREND 🟢' if score>=70 else ('UPTREND_UNDER_PRESSURE 🟡' if score>=50 else 'MARKET_IN_CORRECTION 🔴')
        return mode, score, details
    except Exception as e:
        return 'ERROR', 0, {'error':str(e)}

# ==================== RS / Trend Template / VCP ====================
def calc_rs(df):
    try:
        c=df['Close']
        if len(c)<252: return 0
        r1=c.iloc[-1]/c.iloc[-63]-1; r2=c.iloc[-1]/c.iloc[-126]-1
        r3=c.iloc[-1]/c.iloc[-189]-1; r4=c.iloc[-1]/c.iloc[-252]-1
        return (r1*0.4+r2*0.2+r3*0.2+r4*0.2)*100
    except: return 0

def check_tt(df):
    if len(df)<200: return False,0
    df['SMA50']=df['Close'].rolling(50).mean()
    df['SMA150']=df['Close'].rolling(150).mean()
    df['SMA200']=df['Close'].rolling(200).mean()
    r=df.iloc[-1]
    if not (r['Close']>r['SMA150']>r['SMA200']): return False,0
    if not (r['SMA150']>r['SMA200']): return False,0
    if len(df)<221: return False,0
    if df['SMA200'].iloc[-1]<=df['SMA200'].iloc[-21]: return False,0
    if not (r['SMA50']>r['SMA150'] and r['SMA50']>r['SMA200']): return False,0
    if not (r['Close']>r['SMA50']): return False,0
    l52=df['Low'].rolling(252).min().iloc[-1]; h52=df['High'].rolling(252).max().iloc[-1]
    if r['Close']<l52*1.3: return False,0
    if r['Close']<h52*0.75: return False,0
    return True, calc_rs(df)

def detect_vcp(df):
    if len(df)<60: return {'score':0,'status':'データ不足','contractions':0,'vol_dry':False,'tight':False,'pivot_dist':0}
    swings=[]; ct='H'; cp=df.iloc[0]['High']
    for i in range(1,len(df)):
        row=df.iloc[i]
        if ct=='H':
            if row['High']>cp: cp=row['High']
            elif row['Low']<cp*0.95: swings.append({'t':'H','p':cp}); ct='L'; cp=row['Low']
        else:
            if row['Low']<cp: cp=row['Low']
            elif row['High']>cp*1.05: swings.append({'t':'L','p':cp}); ct='H'; cp=row['High']
    if len(swings)<4: return {'score':0,'status':'スイング不足','contractions':0,'vol_dry':False,'tight':False,'pivot_dist':0}
    declines=[]
    for i in range(len(swings)-1):
        if swings[i]['t']=='H' and swings[i+1]['t']=='L':
            declines.append((swings[i]['p']-swings[i+1]['p'])/swings[i]['p'])
    cc=sum(1 for j in range(1,len(declines)) if declines[j]<declines[j-1]*0.85)
    df['vm50']=df['Volume'].rolling(50).mean()
    rv=df['Volume'].iloc[-5:].mean(); vm=df['vm50'].iloc[-1]
    vd=rv<vm*0.7 if vm>0 else False
    rr=(df['High'].iloc[-5:]-df['Low'].iloc[-5:]).mean()
    pr=(df['High'].iloc[-20:-5]-df['Low'].iloc[-20:-5]).mean()
    tight=rr<pr*0.5 if pr>0 else False
    hs=[s for s in swings if s['t']=='H']
    pivot=hs[-1]['p'] if hs else df['Close'].iloc[-1]
    pd=(pivot-df['Close'].iloc[-1])/pivot*100
    score=min(cc,3)*20 + (20 if vd else 0) + (15 if tight else 0) + (10 if 0<=pd<=5 else 0)
    stt='✅ VCP成立' if score>=70 else ('🟡 VCP形成中' if score>=50 else ('🔸 収縮進行中' if score>=30 else '❌ 未成立'))
    return {'score':score,'status':stt,'contractions':cc,'vol_dry':vd,'tight':tight,'pivot_dist':pd}

def check_fund(ticker):
    try:
        q=yf.Ticker(ticker).quarterly_financials
        if q is None or q.empty: return False,{}
        info={}
        for k in ['Diluted EPS','Basic EPS']:
            if k in q.index and len(q.loc[k])>=8:
                e=q.loc[k]; g=(e.iloc[0]-e.iloc[4])/abs(e.iloc[4])*100 if e.iloc[4]!=0 else 0
                info['EPS成長']=f'{g:.1f}%'; info['EPS_OK']=g>=20; break
        if 'Total Revenue' in q.index and len(q.loc['Total Revenue'])>=8:
            r=q.loc['Total Revenue']; g=(r.iloc[0]-r.iloc[4])/abs(r.iloc[4])*100 if r.iloc[4]!=0 else 0
            info['売上成長']=f'{g:.1f}%'; info['売上_OK']=g>=15
        return (info.get('EPS_OK',False) or info.get('売上_OK',False)), info
    except: return False,{}

# ==================== UI ====================
st.markdown("# 📈 Mark Minervini SEPA Screener")
st.markdown("##### Market 360 × Trend Template × VCP")
st.markdown("---")

mode, score, details = evaluate_market_360()
c1,c2,c3=st.columns([2,1,1])
with c1: st.markdown(f"## {mode}")
with c2:
    color='#00C853' if score>=70 else ('#FFD600' if score>=50 else '#FF1744')
    st.markdown(f'<div style="background:#1E2130;border-radius:12px;padding:1rem;text-align:center;border:1px solid {color};"><div style="font-size:2rem;font-weight:700;color:{color};">{score}/100</div><div style="font-size:0.8rem;color:#8892A4;">Market 360</div></div>',unsafe_allow_html=True)
with c3:
    st.markdown(f'<div style="background:#1E2130;border-radius:12px;padding:1rem;text-align:center;"><div style="font-size:1.2rem;color:#E0E0E0;">{details.get("VIX","N/A")}</div><div style="font-size:0.8rem;color:#8892A4;">VIX</div></div>',unsafe_allow_html=True)

with st.sidebar:
    st.markdown("## ⚙️ 設定")
    uo=st.selectbox("ユニバース",["S&P 500 上位30","S&P 500 上位50","Nasdaq 100 上位30"],index=0)
    vt=st.slider("VCP最低スコア",20,80,40,5)
    mr=st.slider("最大表示数",5,30,15,5)
    if uo=="S&P 500 上位30": universe=get_sp500_list()[:30]
    elif uo=="S&P 500 上位50": universe=get_sp500_list()[:50]
    else: universe=['AAPL','MSFT','AMZN','NVDA','GOOGL','META','TSLA','AVGO','COST','NFLX','AMD','ADBE','CRM','QCOM','TXN','INTU','AMAT','MU','ADI','LRCX','INTC','PYPL','BKNG','ISRG','REGN','VRTX','GILD','AMGN','PANW','SNPS']
    st.markdown(f"対象: **{len(universe)}** 銘柄")
    run_btn=st.button("🚀 スクリーニング実行",use_container_width=True,type="primary")
    st.markdown("---"); st.caption("完全無料・APIキー不要")

if run_btn:
    with st.spinner("🔄 RS計算 + スクリーニング中..."):
        pb=st.progress(0,text="RS計算中...")
        rs_map={}
        for i,sym in enumerate(universe):
            try:
                df=download_data(sym,'2y')
                if len(df)>=200:
                    raw=calc_rs(df); _,ind=get_industry(sym)
                    rs_map[sym]={'raw':raw,'industry':ind}
            except: pass
            if (i+1)%10==0: pb.progress((i+1)/len(universe),text=f"RS計算中... {i+1}/{len(universe)}")
        df_rs=pd.DataFrame.from_dict(rs_map,orient='index')
        ic=df_rs['industry'].value_counts(); vi=ic[ic>=2].index
        df_rs['irs']=0.0; mask=df_rs['industry'].isin(vi)
        if mask.sum()>0: df_rs.loc[mask,'irs']=df_rs[mask].groupby('industry')['raw'].rank(pct=True)*100
        ir_map=df_rs['irs'].to_dict()
        pb.empty()
        sp=st.progress(0,text="スクリーニング中...")
        results=[]
        for i,sym in enumerate(universe):
            r={'ticker':sym,'passed':False,'tt':False,'rs_raw':0,'irs':0,'vcp_score':0,'vcp_status':'','vcp':{},'fund_ok':False,'fund':{},'df':None}
            try:
                df=download_data(sym,'2y')
                if df.empty or len(df)<200: continue
                r['df']=df
                tt_ok,rs_raw=check_tt(df); r['tt']=tt_ok; r['rs_raw']=rs_raw
                if not tt_ok: continue
                irs=ir_map.get(sym,0); r['irs']=irs
                if irs<70: continue
                fok,fi=check_fund(sym); r['fund_ok']=fok; r['fund']=fi
                if not fok: continue
                v=detect_vcp(df); r['vcp_score']=v['score']; r['vcp_status']=v['status']; r['vcp']=v
                if v['score']>=vt: r['passed']=True; results.append(r)
            except: pass
            if (i+1)%10==0: sp.progress((i+1)/len(universe),text=f"スクリーニング中... {i+1}/{len(universe)}")
        sp.empty()
        results.sort(key=lambda x:x['vcp_score'],reverse=True)
        st.session_state['results']=results[:mr]
        st.session_state['mode']=mode

if 'results' in st.session_state and st.session_state['results']:
    st.markdown("---")
    if st.session_state.get('mode','').startswith('MARKET_IN_CORRECTION'):
        st.warning("⚠️ Market in Correction — 参考表示")
    st.markdown(f"### 🔍 仕掛け候補 ({len(st.session_state['results'])}銘柄)")
    for i,r in enumerate(st.session_state['results']):
        c1,c2,c3=st.columns([2,2,1])
        with c1: st.markdown(f"### {i+1}. {r['ticker']}"); st.markdown(r['vcp_status'])
        with c2:
            sc=r['vcp_score']; bc='#00E676' if sc>=70 else ('#FFD600' if sc>=50 else '#FF9100')
            st.markdown(f'<div style="margin-top:0.5rem;"><div style="display:flex;justify-content:space-between;font-size:0.8rem;color:#8892A4;"><span>VCP</span><span>{sc}/100</span></div><div style="height:6px;border-radius:3px;background:#2D3143;"><div style="height:100%;width:{sc}%;background:{bc};border-radius:3px;"></div></div></div>',unsafe_allow_html=True)
            v=r['vcp']; cc1,cc2,cc3=st.columns(3)
            cc1.metric('収縮',v.get('contractions',0)); cc2.metric('Dry','✅' if v.get('vol_dry') else '❌'); cc3.metric('Tight','✅' if v.get('tight') else '❌')
        with c3: st.metric('業種RS',f"{r['irs']:.0f}"); st.metric('RS生値',f"{r['rs_raw']:.1f}")
        with st.expander(f"📈 {r['ticker']} チャート"):
            df=r.get('df')
            if df is not None and len(df)>50:
                fig=make_subplots(rows=2,cols=1,shared_xaxes=True,vertical_spacing=0.03,row_heights=[0.7,0.3])
                fig.add_trace(go.Candlestick(x=df.index[-90:],open=df['Open'].iloc[-90:],high=df['High'].iloc[-90:],low=df['Low'].iloc[-90:],close=df['Close'].iloc[-90:],name='価格',increasing_line_color='#00E676',decreasing_line_color='#FF1744'),row=1,col=1)
                if 'SMA50' in df.columns: fig.add_trace(go.Scatter(x=df.index[-90:],y=df['SMA50'].iloc[-90:],mode='lines',name='50SMA',line=dict(color='#448AFF',width=1)),row=1,col=1)
                if 'SMA150' in df.columns: fig.add_trace(go.Scatter(x=df.index[-90:],y=df['SMA150'].iloc[-90:],mode='lines',name='150SMA',line=dict(color='#FFD600',width=1)),row=1,col=1)
                if 'SMA200' in df.columns: fig.add_trace(go.Scatter(x=df.index[-90:],y=df['SMA200'].iloc[-90:],mode='lines',name='200SMA',line=dict(color='#FF9100',width=1)),row=1,col=1)
                fig.add_trace(go.Bar(x=df.index[-90:],y=df['Volume'].iloc[-90:],name='出来高',marker_color='#448AFF',opacity=0.4),row=2,col=1)
                fig.update_layout(template='plotly_dark',height=450,xaxis_rangeslider_visible=False,showlegend=False,margin=dict(l=10,r=10,t=20,b=10))
                st.plotly_chart(fig,use_container_width=True)
        st.markdown("---")
elif run_btn:
    st.markdown("---"); st.info("🔍 条件に合致する銘柄は見つかりませんでした。"); st.caption("「待つこともトレードの一部。」")

st.markdown("---"); st.caption("免責事項: 投資判断は自己責任で。データ: Yahoo Finance")
ENDOFFILE