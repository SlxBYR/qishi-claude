/* Every edge frame uses the same original drawing. Small, bounded deformations
   follow continuous state; there is no per-frame image swap or optical-flow warp. */
(function (global) {
  'use strict';
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const ease = t => t * t * (3 - 2 * t);
  // Exact critically damped integration. Retargeting preserves position AND velocity.
  function approach(state, target, seconds, frequency = 12) {
    const dt = Math.max(0, Math.min(seconds, .032));
    const displacement = state.value - target;
    const c = state.velocity + frequency * displacement;
    const decay = Math.exp(-frequency * dt);
    state.value = target + (displacement + c * dt) * decay;
    state.velocity = (state.velocity - frequency * c * dt) * decay;
    return state.value;
  }
  function edgeRig(progress, clock, reduced = false) {
    const amplitude = reduced ? 0 : ease(clamp(progress));
    const packet = seconds => {
      const cycle = ((seconds % 10) + 10) % 10;
      const t = (cycle - 6) / 2.4;
      return t > 0 && t < 1 ? 16 * t * t * (1 - t) * (1 - t) : 0;
    };
    return { wave: .045 * packet(clock) * amplitude,
      hair: .0012 * packet(clock - .16) * amplitude, breath: 0 };
  }
  global.QishiMotion = { clamp, ease, approach, edgeRig };
  if (typeof document === 'undefined' || !global.qishiMotionData) return;
  const data = global.qishiMotionData;
  const canvas = document.createElement('canvas');
  canvas.id = 'qishi-motion'; canvas.setAttribute('aria-hidden', 'true');
  document.body.appendChild(canvas);
  const gl = canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: false, preserveDrawingBuffer: true });
  if (!gl) { canvas.remove(); return; }
  const vertex = `attribute vec2 point; void main(){gl_Position=vec4(point,0.,1.);}`;
  const fragment = `precision highp float;
    uniform sampler2D art, previous;
    uniform vec2 viewport, armPivot, armCenter, faceCenter;
    uniform vec4 rect, pose; uniform vec3 alignment;
    uniform vec2 deformation; uniform float bridge;
    vec2 displacement(vec2 q) {
      vec2 d=(q-armCenter)/vec2(.13,.145);
      float weight=1.-smoothstep(.15,1.,dot(d,d));
      // Five facial features stay rigid; only the small hand region may rotate.
      float faceGuard=smoothstep(1.,1.35,length((q-faceCenter)/vec2(.18,.14)));
      float angle=deformation.x;
      float co=cos(angle),si=sin(angle);
      vec2 delta=(mat2(co,si,-si,co)*(q-armPivot)-(q-armPivot))*weight*faceGuard;
      float hair=smoothstep(.53,.72,q.y)*(1.-smoothstep(.87,.98,q.y))
        *smoothstep(.16,.32,abs(q.x-.5));
      delta.x+=sign(q.x-.5)*deformation.y*hair;
      return delta;
    }
    void main(){
      vec2 screen=vec2(gl_FragCoord.x,viewport.y-gl_FragCoord.y);
      vec2 pivot=rect.xy+rect.zw*vec2(.5,.28);
      vec2 p=screen-pivot-pose.xy;
      float co=cos(pose.z),si=sin(pose.z);
      p=mat2(co,-si,si,co)*p/pose.w;
      p=(p+pivot-rect.xy)/rect.zw;
      vec2 base=(p-alignment.yz)/alignment.x,q=base;
      for(int i=0;i<4;i++)q=base-displacement(q);
      vec4 color=vec4(0.);
      if(all(greaterThanEqual(q,vec2(0.)))&&all(lessThanEqual(q,vec2(1.))))color=texture2D(art,q);
      gl_FragColor=mix(texture2D(previous,screen/viewport),color,bridge);
    }`;
  function shader(kind, source) {
    const s = gl.createShader(kind); gl.shaderSource(s, source); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  }
  let program;
  try {
    program = gl.createProgram(); gl.attachShader(program, shader(gl.VERTEX_SHADER, vertex));
    gl.attachShader(program, shader(gl.FRAGMENT_SHADER, fragment)); gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
  } catch (error) { console.error('Motion renderer:', error); canvas.remove(); return; }
  gl.useProgram(program);
  const buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]), gl.STATIC_DRAW);
  const location = gl.getAttribLocation(program, 'point'); gl.enableVertexAttribArray(location);
  gl.vertexAttribPointer(location, 2, gl.FLOAT, false, 0, 0);
  const uniforms = Object.fromEntries(['art','previous','viewport','rect','pose','alignment','armPivot','armCenter','faceCenter','deformation','bridge'].map(x => [x,gl.getUniformLocation(program,x)]));
  ['art','previous'].forEach((x,i) => gl.uniform1i(uniforms[x],i));
  function texture(source, width, height, filter = gl.LINEAR) {
    const binding = gl.getParameter(gl.TEXTURE_BINDING_2D);
    const premultiply = gl.getParameter(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL);
    const flip = gl.getParameter(gl.UNPACK_FLIP_Y_WEBGL);
    const tex = gl.createTexture();
    try {
      gl.bindTexture(gl.TEXTURE_2D,tex);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,filter); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,filter);
      gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
      // Premultiply DOM artwork before linear filtering, including snapshots.
      // Packed flow bytes are data: their alpha channel is the high Y byte.
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,!width);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,false);
      if(width) gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,width,height,0,gl.RGBA,gl.UNSIGNED_BYTE,source);
      else gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,source);
    } finally {
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL,premultiply);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,flip);
      gl.bindTexture(gl.TEXTURE_2D,binding);
    }
    return tex;
  }
  const transparent = texture(new Uint8Array(4),1,1);
  let prior = transparent, bridgeStart = -Infinity, enabled = false, last = null;
  let finishRAF = null, generation = 0, ready = false, failed = false, failure = null;
  const images = new Map();
  const load = Object.entries(data.images).map(([id,meta]) => new Promise((resolve,reject) => {
    const image = new Image(); image.onload = async () => {
      try { await image.decode(); images.set(id,texture(image)); resolve(); } catch(e) { reject(e); }
    }; image.onerror = reject; image.src = meta.url;
  }));
  Promise.all(load).then(() => { ready=true; }, error => { failed=true; failure=String(error); });
  function size() {
    const dpr=Math.min(global.devicePixelRatio||1,2), w=Math.round(innerWidth*dpr), h=Math.round(innerHeight*dpr);
    if(canvas.width!==w||canvas.height!==h){canvas.width=w;canvas.height=h;}
    gl.viewport(0,0,w,h); gl.uniform2f(uniforms.viewport,w,h); return dpr;
  }
  function capture() {
    const copy=document.createElement('canvas'); copy.width=canvas.width||innerWidth; copy.height=canvas.height||innerHeight;
    const ctx=copy.getContext('2d');
    const releasing=document.documentElement.classList.contains('qishi-motion-releasing');
    if(!enabled||releasing) {
      const r=typeof shownRect==='function' ? shownRect() : null;
      if(r&&typeof active!=='undefined'&&active.complete){
        const ratio=copy.width/innerWidth;
        ctx.save();ctx.scale(ratio,ratio);
        ctx.globalAlpha=enabled ? clamp(Number(document.documentElement.style.getPropertyValue('--qishi-rest-opacity'))||0) : 1;
        ctx.drawImage(active,r.left,r.top,r.width,r.height);ctx.restore();
      }
    }
    if(enabled){
      ctx.globalAlpha=releasing ? clamp(Number(canvas.style.opacity)) : 1;
      ctx.drawImage(canvas,0,0);ctx.globalAlpha=1;
    }
    if(prior!==transparent) gl.deleteTexture(prior);
    prior=texture(copy); bridgeStart=performance.now();
  }
  function resetReleasePresentation() {
    canvas.style.opacity='';
    document.documentElement.classList.remove('qishi-motion-releasing');
    document.documentElement.style.removeProperty('--qishi-rest-opacity');
  }
  function begin(blend = true) {
    if(!ready||failed) return false;
    ++generation; if(finishRAF!==null) cancelAnimationFrame(finishRAF); finishRAF=null;
    // Snapshot before resizing clears the WebGL buffer, and before removing a
    // partly completed release: a re-grab begins from the actual visible pixels.
    if(enabled){capture();size();}else{size();capture();}
    if(!blend) bridgeStart=-Infinity;
    resetReleasePresentation();enabled=true;
    document.documentElement.classList.add('qishi-motion-active'); return true;
  }
  function paintRig(id,rect,pose={x:0,y:0,rotation:0,scale:1},rig={wave:0,hair:0,breath:0}) {
    if(!ready||!enabled||!images.has(id)) return false;
    const dpr=size(),meta=data.images[id];
    [images.get(id),prior].forEach((tex,i)=>{gl.activeTexture(gl.TEXTURE0+i);gl.bindTexture(gl.TEXTURE_2D,tex);});
    gl.uniform4f(uniforms.rect,rect.x*dpr,rect.y*dpr,rect.width*dpr,rect.height*dpr);
    gl.uniform4f(uniforms.pose,(pose.x||0)*dpr,(pose.y||0)*dpr,(pose.rotation||0)*Math.PI/180,pose.scale||1);
    gl.uniform3f(uniforms.alignment,meta.scale,meta.offsetX,meta.offsetY);
    for(const key of ['armPivot','armCenter','faceCenter'])gl.uniform2f(uniforms[key],...meta.rig[key]);
    gl.uniform2f(uniforms.deformation,rig.wave||0,rig.hair||0);
    gl.uniform1f(uniforms.bridge,ease(clamp((performance.now()-bridgeStart)/220)));
    gl.drawArrays(gl.TRIANGLES,0,6);
    last={a:id,b:id,t:0,rect:{...rect},pose:{...pose},rig:{...rig},hasFlow:false};return true;
  }
  function end(immediate=false) {
    if(!immediate&&finishRAF!==null) return;
    ++generation; if(finishRAF!==null) cancelAnimationFrame(finishRAF); finishRAF=null;
    if(!enabled){resetReleasePresentation();return;}
    const token=generation;
    const clear=()=>{enabled=false;last=null;resetReleasePresentation();document.documentElement.classList.remove('qishi-motion-active');gl.clear(gl.COLOR_BUFFER_BIT);};
    if(immediate){clear();return;}
    // Finish from the last presented pixels; no drawing or transform snaps on release.
    const start=performance.now(); canvas.style.opacity='1';
    document.documentElement.classList.add('qishi-motion-releasing');
    const tick=now=>{
      if(token!==generation) return;
      const t=ease(clamp((now-start)/180));canvas.style.opacity=String(1-t);
      document.documentElement.style.setProperty('--qishi-rest-opacity',String(t));
      if(t<1) finishRAF=requestAnimationFrame(tick);
      else {finishRAF=null;clear();}
    };finishRAF=requestAnimationFrame(tick);
  }
  function hit(x,y) {
    if(!enabled) return null;
    if(x<0||y<0||x>=innerWidth||y>=innerHeight)return false;
    const px=new Uint8Array(4),dpr=canvas.width/innerWidth;
    gl.readPixels(Math.floor(x*dpr),canvas.height-1-Math.floor(y*dpr),1,1,gl.RGBA,gl.UNSIGNED_BYTE,px);
    return px[3]>20;
  }
  canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();failed=true;end(true);});
  global.qishiMotionRenderer={begin,paintRig,end,hit,inspect:()=>({ready,failed,failure,enabled,interpolating:false,rigged:!!last,last})};
})(window);
