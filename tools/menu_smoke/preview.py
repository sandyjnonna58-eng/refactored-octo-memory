import numpy as np, sys, os, subprocess
from PIL import Image
OUT=sys.argv[1]; dst=sys.argv[2]; secs=float(sys.argv[3]) if len(sys.argv)>3 else 20
W,H=960,540; T=20.0; N=20; fps=12
bg=np.asarray(Image.open(OUT+"menu_bg_soft.jpg").convert("RGB").resize((W,H),Image.LANCZOS)).astype(float)/255
def ld(p):
    im=np.asarray(Image.open(p)).astype(np.float32)
    # по каналам: Pillow сам домножает RGBA на альфу при ресайзе, а у нас цвет уже домножен
    return np.stack([np.asarray(Image.fromarray(im[...,c],"F").resize((W,H),Image.BILINEAR)) for c in range(4)],-1)/255
fr=[ld(OUT+"frames/smoke_%02d.png"%(i+1)) for i in range(N)]
p=subprocess.Popen(["ffmpeg","-v","error","-y","-f","rawvideo","-pix_fmt","rgb24","-s","%dx%d"%(W,H),"-r",str(fps),"-i","-","-c:v","libx264","-pix_fmt","yuv420p","-crf","20",dst],stdin=subprocess.PIPE)
for k in range(int(secs*fps)):
    t=k/fps; x=(t%T)/T*N; i=int(x)%N; j=(i+1)%N; f=x-int(x)
    a=fr[i]; b=fr[j]
    out=bg*(1-(1-f)*a[...,3:])*(1-f*b[...,3:])+(1-f)*a[...,:3]+f*b[...,:3]
    p.stdin.write((np.clip(out,0,1)*255).astype(np.uint8).tobytes())
p.stdin.close(); p.wait()
