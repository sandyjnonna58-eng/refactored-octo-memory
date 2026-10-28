# Картинки меню в стиле "хакерского" терминала (cl_menu_wd.lua): точечные фоны, логотип-граффити, картинки карточек.
# Запуск из корня репозитория: python3 tools/menu_wd/gen.py materials/rem_wd/
import numpy as np, sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
OUT=sys.argv[1]; os.makedirs(OUT,exist_ok=True)
W,H=1280,720
rng=np.random.default_rng(3)

def stipple(gray, step=6, rmax=2.6, gamma=0.8, jitter=1.6, seed=0):
    # белые точки на чёрном: размер точки по яркости, сетка чуть сбита
    g=np.random.default_rng(seed)
    h,w=gray.shape
    img=Image.new("L",(w,h),0); d=ImageDraw.Draw(img)
    for y in range(0,h,step):
        for x in range(0,w,step):
            v=gray[min(h-1,y),min(w-1,x)]**gamma
            if v<0.08: continue
            r=rmax*np.sqrt(v)
            jx,jy=g.uniform(-jitter,jitter,2)
            cx,cy=x+jx,y+jy
            d.ellipse([cx-r,cy-r,cx+r,cy+r],fill=int(150+105*v))
    return img

def save(img,name):
    img.convert("RGB").save(OUT+name+".png",optimize=True)

# 1) город
city=Image.open("materials/rem_menu/menu_bg.jpg").convert("L").resize((W,H),Image.LANCZOS)
c=np.asarray(city).astype(float)/255
c=np.clip((c-0.2)/0.75,0,1)**1.5
save(stipple(c,seed=1),"scene_city")

# 2) кольца-мишень
yy,xx=np.mgrid[0:H,0:W].astype(float)
r=np.hypot(xx-W*0.52,yy-H*0.5)
n=np.asarray(Image.fromarray((rng.random((H//8,W//8))*255).astype(np.uint8)).resize((W,H),Image.BICUBIC)).astype(float)/255
rings=((np.sin(r/26.0)>0.35)&(r<H*0.62)).astype(float)*np.clip(1-r/(H*0.7),0.15,1)
rings*=np.clip(0.55+n*0.9,0,1)
cross=((np.abs(xx-W*0.52)<3)|(np.abs(yy-H*0.5)<3))&(r<H*0.2)
rings=np.maximum(rings,cross*0.9)
save(stipple(rings,step=6,seed=2),"scene_rings")

# 3) рой пиксельных черепов (свой рисунок 7x8)
SK=["0111110","1111111","1101011","1101011","1111111","0110110","0011100","0101010"]
sk=np.array([[1 if ch=="1" else 0 for ch in row] for row in SK],float)
field=np.zeros((H,W))
for _ in range(260):
    s=int(rng.uniform(4,14)); x=int(rng.uniform(-40,W)); y=int(rng.uniform(-40,H))
    b=rng.uniform(0.25,1.0)*(0.4+0.6*np.clip(1-abs(x-W*0.55)/(W*0.6),0,1))
    spr=np.kron(sk,np.ones((s,s)))*b
    h,w=spr.shape
    ys,xs=max(0,y),max(0,x); ye,xe=min(H,y+h),min(W,x+w)
    if ye<=ys or xe<=xs: continue
    field[ys:ye,xs:xe]=np.maximum(field[ys:ye,xs:xe],spr[ys-y:ye-y,xs-x:xe-x])
save(stipple(field,step=5,rmax=2.2,seed=3),"scene_skulls")

# 4) логотип FUNKAS: серое граффити с подтёками
font=ImageFont.truetype("resource/fonts/FingerPaint-Regular.ttf",260)
LW,LH=1100,520
logo=Image.new("L",(LW,LH),0); d=ImageDraw.Draw(logo)
d.text((LW/2,LH*0.42),"FUNKAS",font=font,fill=255,anchor="mm")
a=np.asarray(logo).astype(float)/255
# подтёки вниз из нижних краёв букв
drip=np.zeros_like(a)
cols=rng.choice(LW,70,replace=False)
for x in cols:
    ys=np.where(a[:,x]>0.5)[0]
    if len(ys)==0: continue
    y0=ys.max(); ln=int(rng.uniform(15,110)); wd=int(rng.uniform(3,7))
    drip[y0:min(LH,y0+ln),max(0,x-wd//2):x+wd//2+1]=1
    yb=min(LH-1,y0+ln); drip[max(0,yb-wd):yb+wd,max(0,x-wd):x+wd]=1
a=np.maximum(a,drip)
spray=Image.fromarray((a*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2.2))
sa=np.asarray(spray).astype(float)/255
speck=rng.random(sa.shape)
sa=np.clip(sa*(0.75+0.25*speck)+(speck>0.995)*(np.asarray(spray.filter(ImageFilter.GaussianBlur(14)))/255>0.05)*0.5,0,1)
rgba=np.dstack([np.full_like(sa,200),np.full_like(sa,200),np.full_like(sa,200),sa*255]).astype(np.uint8)
Image.fromarray(rgba,"RGBA").save(OUT+"logo.png",optimize=True)

# 5) картинки карточек: кусочки точечных фонов
crops={"card_discord":("scene_city",(560,140,1040,410)),"card_appearance":("scene_skulls",(380,180,860,450)),
       "card_skills":("scene_rings",(420,180,900,450)),"card_achievements":("scene_city",(60,60,540,330)),
       "card_settings":("scene_skulls",(700,330,1180,600))}
for name,(src,box) in crops.items():
    Image.open(OUT+src+".png").crop(box).save(OUT+name+".png",optimize=True)
print("ok")
