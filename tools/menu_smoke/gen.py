# Дым главного меню: размытый фон + зацикленные кадры "кипящего" дыма (premultiplied RGBA) поверх столбов дыма.
# Запуск из корня репозитория: python3 tools/menu_smoke/gen.py out/  (берёт materials/rem_menu/menu_bg.jpg),
# потом out/menu_bg_soft.jpg -> materials/rem_menu/, out/frames/*.png -> materials/rem_menu/smoke/.
# Посмотреть заранее: python3 tools/menu_smoke/preview.py out/ preview.mp4 40
import numpy as np, sys, os
from PIL import Image, ImageFilter
SP=os.path.dirname(os.path.abspath(__file__))+"/"
OUT=sys.argv[1] if len(sys.argv)>1 else SP+"out/"
os.makedirs(OUT,exist_ok=True)
W,H=960,540              # расчёт
FW,FH=800,450            # размер кадров
T=20.0; N=20             # период и число кадров
rng=np.random.default_rng(7)
I=Image

src=I.open("materials/rem_menu/menu_bg.jpg").convert("RGB")
# 1) размытый фон с мягким свечением, как на видео
big=src.filter(ImageFilter.GaussianBlur(3.8))
a=np.asarray(big).astype(float)/255
glow=np.asarray(src.filter(ImageFilter.GaussianBlur(28))).astype(float)/255
bright=np.clip((glow.mean(2,keepdims=True)-0.45)/0.55,0,1)
soft=np.clip(a+glow*bright*0.22,0,1)
# лёгкая дымка: тени чуть светлее и теплее, как на видео
soft=np.clip(soft*0.93+np.array([0.075,0.05,0.025]),0,1)
I.fromarray((soft*255).astype(np.uint8)).save(OUT+"menu_bg_soft.jpg",quality=90)
bgs=np.asarray(I.fromarray((soft*255).astype(np.uint8)).resize((W,H),I.LANCZOS)).astype(float)/255

# 2) маска столбов дыма
lum=np.asarray(src.resize((W,H),I.LANCZOS).convert("L")).astype(float)/255
mean=np.asarray(I.fromarray((lum*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(4))).astype(float)/255
sq=np.asarray(I.fromarray((lum**2*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(4))).astype(float)/255
std=np.sqrt(np.clip(sq-mean**2,0,1)); smooth=np.clip(1-std/0.08,0,1)
# без тонких линий по краям гор и крыш: маска гладкости сама размыта
smooth=np.asarray(I.fromarray((smooth*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(8))).astype(float)/255
yy,xx=np.mgrid[0:H,0:W].astype(float)
def ell(cx,cy,rx,ry): return np.clip(1.2-(((xx-cx)/rx)**2+((yy-cy)/ry)**2),0,1)
blobs=[(105,130,140,95),(60,235,70,60),(250,225,55,38),(340,182,55,34),(412,226,60,28),(140,312,125,36),(455,318,36,40),(600,332,85,28),(690,350,65,24),(845,385,80,30)]
M=np.zeros((H,W))
for b in blobs: M=np.maximum(M,ell(*b))
M=M*smooth**1.5
# яркое небо за дымом не трогаем: иначе по краю маски видна дуга
sky=np.clip((lum-0.60)/0.15,0,1)*np.clip((260-yy)/80,0,1)
M=M*(1-sky)
M=np.asarray(I.fromarray((np.clip(M,0,1)*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(10))).astype(float)/255

# 3) периодический fBm-шум (FFT)
def fbm(seed,beta=2.0,kmax=0.18):
    g=np.random.default_rng(seed)
    wn=g.standard_normal((H,W))
    fy=np.fft.fftfreq(H)[:,None]; fx=np.fft.rfftfreq(W)[None,:]
    k=np.sqrt(fx**2+fy**2); k[0,0]=1
    filt=k**(-beta/2)*np.exp(-(k/kmax)**2); filt[0,0]=0
    n=np.fft.irfft2(np.fft.rfft2(wn)*filt,s=(H,W))
    return (n-n.mean())/n.std()
A=fbm(1,beta=3.2,kmax=0.045); B=fbm(2,beta=3.2,kmax=0.045); C=fbm(3,beta=3.4,kmax=0.015)
# поле потока: вверх-вправо + завихрения (curl от низкочастотного шума), пикс/с при W=960
P=fbm(4,beta=3.0,kmax=0.02)
gy,gx=np.gradient(P)
cs=1.0/np.abs(np.stack([gx,gy])).max()
vx=0.55+gy*cs*0.9; vy=-0.30-gx*cs*0.9

def sample(F,dx,dy):
    # билинейная выборка периодического поля со смещением
    x=(xx-dx)%W; y=(yy-dy)%H
    x0=np.floor(x).astype(int); y0=np.floor(y).astype(int); fx=x-x0; fy=y-y0; x0%=W; y0%=H
    x1=(x0+1)%W; y1=(y0+1)%H
    return (F[y0,x0]*(1-fx)*(1-fy)+F[y0,x1]*fx*(1-fy)+F[y1,x0]*(1-fx)*fy+F[y1,x1]*fx*fy)

# направление на солнце (свет на комках)
sunx,suny=650,20
lx=sunx-xx; ly=suny-yy; ln=np.sqrt(lx**2+ly**2)+1e-6; lx/=ln; ly/=ln
tint=np.array([0.95,0.80,0.66])  # дым чуть серее фона

def density(t):
    # два сдвинутых по фазе слоя, каждый течёт по полю потока и плавно сменяет другой (бесшовный цикл)
    p1=(t/T)%1; p2=(t/T+0.5)%1
    w1=1-abs(2*p1-1); w2=1-w1
    d1=sample(A,vx*p1*T,vy*p1*T); d2=sample(B,vx*p2*T,vy*p2*T)
    # крупное медленное "кипение" по кругу
    ang=2*np.pi*t/T
    big=sample(C,18*np.cos(ang),10*np.sin(ang))
    return (d1*w1+d2*w2)/np.sqrt(w1**2+w2**2)*0.85+big*0.5

def frame(t):
    d=density(t)
    # клубы: мягкие выпуклые комки
    puff=1/(1+np.exp(-(d*2.2-0.2)))
    s=7.0
    dsun=sample(puff,-lx*s,-ly*s)
    shade=np.clip(0.5+(puff-dsun)*2.2,0,1)   # сторона к солнцу светлее, обратная - в тени
    lit=0.78+0.46*shade
    grey=bgs.mean(2,keepdims=True)*tint
    col=bgs*(1-0.30*puff[...,None])+grey*0.30*puff[...,None]
    col=np.clip(col*lit[...,None],0,1)
    alpha=np.clip(M*(0.30+0.60*puff),0,1)
    return col,alpha

os.makedirs(OUT+"frames",exist_ok=True)
for i in range(N):
    col,al=frame(i*T/N)
    pm=np.dstack([col*al[...,None],al])
    # уменьшаем без "звона" (LANCZOS даёт кольца по краям маски), премультиплицированный цвет не выше альфы
    small=np.stack([np.asarray(I.fromarray(pm[...,c].astype(np.float32),"F").resize((FW,FH),I.BOX)) for c in range(4)],-1)
    small[...,:3]=np.minimum(small[...,:3],small[...,3:])
    im=I.fromarray((np.clip(small,0,1)*255+0.5).astype(np.uint8),"RGBA")
    im.save(OUT+"frames/smoke_%02d.png"%(i+1),optimize=True)
np.save(OUT+"mask.npy",M)
print("ok")
