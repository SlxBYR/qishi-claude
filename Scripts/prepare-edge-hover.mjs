#!/usr/bin/env node
// Mechanical extraction/composition only. All character artwork comes from imagegen atlases.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const art=path.resolve(process.argv[2]||path.join(root,'..','Claude娘-边缘悬停'));
const dest=path.join(root,'Resources','Claude','edge-hover');
const temp=path.join(art,'.preview-frames');
fs.mkdirSync(dest,{recursive:true});fs.mkdirSync(temp,{recursive:true});
const ffmpeg=process.env.FFMPEG||'/opt/homebrew/bin/ffmpeg';
const ffprobe=process.env.FFPROBE||'/opt/homebrew/bin/ffprobe';
const run=(a,input)=>execFileSync(ffmpeg,['-v','error',...a],{input,maxBuffer:40e6});
const crcTable=new Uint32Array(256);for(let n=0;n<256;n++){let c=n;for(let k=0;k<8;k++)c=c&1?0xedb88320^(c>>>1):c>>>1;crcTable[n]=c;}
function crc(b){let c=0xffffffff;for(const x of b)c=crcTable[(c^x)&255]^(c>>>8);return(c^0xffffffff)>>>0;}
function chunk(name,data){const t=Buffer.from(name),b=Buffer.alloc(data.length+12);b.writeUInt32BE(data.length);t.copy(b,4);data.copy(b,8);b.writeUInt32BE(crc(Buffer.concat([t,data])),data.length+8);return b;}
function png(w,h,rgba){const hdr=Buffer.alloc(13);hdr.writeUInt32BE(w);hdr.writeUInt32BE(h,4);hdr[8]=8;hdr[9]=6;const scan=Buffer.alloc(h*(w*4+1));for(let y=0;y<h;y++)rgba.copy(scan,y*(w*4+1)+1,y*w*4,(y+1)*w*4);return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',hdr),chunk('IDAT',zlib.deflateSync(scan,{level:6})),chunk('IEND',Buffer.alloc(0))]);}
function decode(file){const {streams:[s]}=JSON.parse(execFileSync(ffprobe,['-v','error','-show_entries','stream=width,height','-of','json',file]));return{w:s.width,h:s.height,data:run(['-i',file,'-f','rawvideo','-pix_fmt','rgba','pipe:1'])};}
function components(im){const{w,h,data}=im,n=w*h,labels=new Int32Array(n),q=new Int32Array(n),cs=[];let label=0;
for(let k=0;k<n;k++){if(labels[k]||data[k*4+3]<80)continue;label++;let a=0,z=0,x0=w,y0=h,x1=0,y1=0;q[z++]=k;labels[k]=label;while(a<z){const p=q[a++],x=p%w,y=(p/w)|0;x0=Math.min(x0,x);y0=Math.min(y0,y);x1=Math.max(x1,x);y1=Math.max(y1,y);for(const j of[x? p-1:-1,x<w-1?p+1:-1,y?p-w:-1,y<h-1?p+w:-1])if(j>=0&&!labels[j]&&data[j*4+3]>=80){labels[j]=label;q[z++]=j;}}cs.push({label,count:z,solid:[x0,y0,x1,y1]});}
const main=cs.filter(c=>c.count>n/100);if(main.length!==16)throw Error(`Expected 16 separate drawn sprites; found ${main.length}. Refuse unsafe grid clipping.`);
const valid=new Set(main.map(c=>c.label));const ownership=new Int32Array(n);let tail=0;for(let i=0;i<n;i++)if(valid.has(labels[i])){ownership[i]=labels[i];q[tail++]=i;}let start=0;
// Attach the original antialias pixels, without inventing or repainting any pixels.
for(let pass=0;pass<6;pass++){const end=tail;for(let i=start;i<end;i++){const p=q[i],x=p%w,y=(p/w)|0;for(const j of[x?p-1:-1,x<w-1?p+1:-1,y?p-w:-1,y<h-1?p+w:-1])if(j>=0&&!ownership[j]&&data[j*4+3]>0){ownership[j]=ownership[p];q[tail++]=j;}}start=end;}
for(const c of main)c.box=[w,h,0,0];const byId=new Map(main.map(c=>[c.label,c]));for(let i=0;i<n;i++){const c=byId.get(ownership[i]);if(!c)continue;const x=i%w,y=(i/w)|0;c.box=[Math.min(c.box[0],x),Math.min(c.box[1],y),Math.max(c.box[2],x),Math.max(c.box[3],y)];}
for(const c of main){const[x0,y0,x1,y1]=c.solid;c.frame=Math.min(3,Math.floor((y0+y1)/2/h*4))*4+Math.min(3,Math.floor((x0+x1)/2/w*4));}main.sort((a,b)=>a.frame-b.frame);if(new Set(main.map(c=>c.frame)).size!==16)throw Error('Ambiguous sprite positions');return{main,ownership};}
function resize(data,w,h,tw,th){return run(['-f','rawvideo','-pixel_format','rgba','-video_size',`${w}x${h}`,'-i','pipe:0','-vf',`premultiply=inplace=1,scale=${tw}:${th}:flags=lanczos,unpremultiply=inplace=1`,'-frames:v','1','-f','rawvideo','-pix_fmt','rgba','pipe:1'],data);}
const sides=['left','right'].filter(s=>fs.existsSync(path.join(art,`${s}-atlas.png`)));
if(!sides.length)throw Error('No atlas inputs found');
const inputs=sides.map(side=>{const im=decode(path.join(art,`${side}-atlas.png`));return{side,im,...components(im)};});
const maxH=Math.max(...inputs.flatMap(t=>t.main.map(c=>c.box[3]-c.box[1]+1))),maxW=Math.max(...inputs.flatMap(t=>t.main.map(c=>c.box[2]-c.box[0]+1)));
const scale=Math.min(576/maxH,608/maxW);const frames={},report={atlasGrid:[4,4],canvas:[640,640],baseline:620,uniformScale:scale,segmentation:'16 separate alpha components; preserve original pixels and antialias fringe; no grid clipping, mirroring or painting',sides:{}};
for(const t of inputs){frames[t.side]=[];report.sides[t.side]=[];for(const c of t.main){const[x0,y0,x1,y1]=c.box,w=x1-x0+1,h=y1-y0+1,b=Buffer.alloc(w*h*4);for(let y=0;y<h;y++)for(let x=0;x<w;x++){const p=(y+y0)*t.im.w+x+x0;if(t.ownership[p]===c.label)t.im.data.copy(b,(y*w+x)*4,p*4,p*4+4);}const tw=Math.round(w*scale),th=Math.round(h*scale),r=resize(b,w,h,tw,th),canvas=Buffer.alloc(640*640*4),dx=Math.round(320-tw/2),dy=620-th;for(let y=0;y<th;y++)r.copy(canvas,((y+dy)*640+dx)*4,y*tw*4,(y+1)*tw*4);const name=`${t.side}-${String(c.frame).padStart(2,'0')}.png`;fs.writeFileSync(path.join(dest,name),png(640,640,canvas));frames[t.side].push(canvas);report.sides[t.side].push({frame:c.frame,sourceBounds:c.box,solidBounds:c.solid,outputBounds:[dx,dy,dx+tw-1,619],touchesAtlasEdge:x0===0||y0===0||x1===t.im.w-1||y1===t.im.h-1});}}
fs.writeFileSync(path.join(art,'frame-qa.json'),JSON.stringify(report,null,2)+'\n');
const cuts=[.46,.47,.48,.41,.34,.27,.20,.15,.12,.13,.14,.14,.14,.14,.14,.14];
const times=[90,70,70,60,60,65,70,80,90,90,100,90,90,90,100,160];
function flat(w,h,color=[251,247,240,255]){const b=Buffer.alloc(w*h*4);for(let i=0;i<w*h;i++)for(let c=0;c<4;c++)b[4*i+c]=color[c];return b;}
function rect(b,w,h,x,y,rw,rh,color){for(let yy=Math.max(0,y|0);yy<Math.min(h,y+rh);yy++)for(let xx=Math.max(0,x|0);xx<Math.min(w,x+rw);xx++){const p=(yy*w+xx)*4;for(let c=0;c<4;c++)b[p+c]=color[c];}}
function composite(bg,bw,bh,fg,fw,fh,dx,dy,clip=[0,0,bw,bh]){for(let y=0;y<fh;y++){const yy=y+dy;if(yy<clip[1]||yy>=clip[3]||yy<0||yy>=bh)continue;for(let x=0;x<fw;x++){const xx=x+dx;if(xx<clip[0]||xx>=clip[2]||xx<0||xx>=bw)continue;const q=(y*fw+x)*4,a=fg[q+3]/255;if(!a)continue;const p=(yy*bw+xx)*4;for(let c=0;c<3;c++)bg[p+c]=Math.round(fg[q+c]*a+bg[p+c]*(1-a));bg[p+3]=255;}}}
const previewSize=400,smalls={};for(const s of sides)smalls[s]=frames[s].map(b=>resize(b,640,640,previewSize,previewSize));
const sequence=[{i:0,ms:650},...times.map((ms,i)=>({i,ms})),{i:15,ms:1200},...[15,14,13,12,11,10,11,12,13,14,15].map(i=>({i,ms:100})),{i:15,ms:650},...Array.from({length:15},(_,k)=>({i:14-k,ms:65})),{i:0,ms:750}];
// Continuous position easing uses 25 presentation frames/s; artwork stays hand drawn.
const sampled=[];let segment=0,start=0;const total=sequence.reduce((n,s)=>n+s.ms,0);
const startCuts=[cuts[sequence[0].i]];for(let k=1;k<sequence.length;k++){const p=sequence[k-1];startCuts[k]=startCuts[k-1]+(cuts[p.i]-startCuts[k-1])*Math.min(1,p.ms/75);}
for(let t=0;t<total;t+=40){while(segment<sequence.length-1&&t>=start+sequence[segment].ms){start+=sequence[segment].ms;segment++;}const now=sequence[segment],u=Math.min(1,(t-start)/75);sampled.push({i:now.i,cut:startCuts[segment]+(cuts[now.i]-startCuts[segment])*u,ms:40});}
const pw=960,ph=440;const concat=[];for(let k=0;k<sampled.length;k++){const{i,cut,ms}=sampled[k],b=flat(pw,ph);rect(b,pw,ph,30,18,438,404,[255,253,249,255]);rect(b,pw,ph,492,18,438,404,[255,253,249,255]);rect(b,pw,ph,29,18,2,404,[177,153,128,255]);rect(b,pw,ph,929,18,2,404,[177,153,128,255]);if(smalls.left)composite(b,pw,ph,smalls.left[i],previewSize,previewSize,Math.round(30-previewSize*cut),20,[30,18,468,422]);if(smalls.right)composite(b,pw,ph,smalls.right[i],previewSize,previewSize,Math.round(930-previewSize*(1-cut)),20,[492,18,930,422]);const f=path.join(temp,`${String(k).padStart(3,'0')}.png`);fs.writeFileSync(f,png(pw,ph,b));concat.push(`file '${f.replaceAll("'","'\\''")}'\nduration ${ms/1000}`);}
concat.push(`file '${path.join(temp,`${String(sampled.length-1).padStart(3,'0')}.png`)}'`);fs.writeFileSync(path.join(temp,'frames.ffconcat'),concat.join('\n')+'\n');
run(['-y','-f','concat','-safe','0','-i',path.join(temp,'frames.ffconcat'),'-filter_complex','split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a','-loop','0',path.join(art,'Claude娘-边缘悬停预览.gif')]);
// Contact sheet: first column retains the original pose, then four drawn action stages.
const mw=1280,mh=600,mont=flat(mw,mh);for(let row=0;row<sides.length;row++){const side=sides[row];const orig=decode(path.join(root,'Resources','Claude',`edge_${side}_peek.webp`));const oh=270,ow=Math.round(orig.w/orig.h*oh);composite(mont,mw,mh,resize(orig.data,orig.w,orig.h,ow,oh),ow,oh,Math.round((256-ow)/2),row*300+20);for(let col=1;col<5;col++){const idx=[0,7,11,13][col-1],sz=280;const r=resize(frames[side][idx],640,640,sz,sz);composite(mont,mw,mh,r,sz,sz,col*256-12,row*300+10);}}fs.writeFileSync(path.join(art,'Claude娘-关键帧对照.png'),png(mw,mh,mont));
fs.writeFileSync(path.join(art,'preview-timing.json'),JSON.stringify({cuts,enterMs:times,sequence},null,2)+'\n');
if(!process.argv.includes('--keep-temp'))fs.rmSync(temp,{recursive:true,force:true});
console.log(JSON.stringify({frames:inputs.length*16,canvas:[640,640],uniformScale:scale,dest,preview:path.join(art,'Claude娘-边缘悬停预览.gif'),qa:path.join(art,'frame-qa.json')}));
