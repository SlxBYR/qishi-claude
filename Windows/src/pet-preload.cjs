'use strict';
const {ipcRenderer}=require('electron');
window.addEventListener('DOMContentLoaded',()=>{let down=null,dragged=false,lastX=0,direction=0,swings=[],lastClick=null;
 const root=document.documentElement,swallow=event=>{event.preventDefault();event.stopImmediatePropagation();};
 // Every way a gesture can end (pointerup, cancel, lost capture, blur, or a move with no button held after
 // Windows swallowed the release) goes through here, so the main process never keeps a stale drag.
 const finish=(event,release)=>{if(!down)return;const p=release?{dragged,x:event.clientX,y:event.clientY,clicks:release}:{dragged,cancel:true};down=null;try{if(event?.pointerId!==undefined&&root.hasPointerCapture(event.pointerId))root.releasePointerCapture(event.pointerId);}catch{}ipcRenderer.send('pet-up',p);};
 document.addEventListener('pointerdown',event=>{if(event.button!==0)return;swallow(event);if(down)finish(event,0);try{root.setPointerCapture(event.pointerId);}catch{}down={x:event.screenX,y:event.screenY};dragged=false;lastX=event.screenX;direction=0;swings=[];ipcRenderer.send('pet-down',down);},true);
 document.addEventListener('pointermove',event=>{if(!down)return;event.preventDefault();if(event.buttons===0){finish(event,0);return;}if(!dragged&&Math.abs(event.screenX-down.x)+Math.abs(event.screenY-down.y)>3)dragged=true;if(dragged){ipcRenderer.send('pet-drag',{x:event.screenX,y:event.screenY});const d=event.screenX-lastX;if(Math.abs(d)>18){const next=Math.sign(d);if(direction&&next!==direction){swings=swings.filter(t=>Date.now()-t<900);swings.push(Date.now());if(swings.length>=2){ipcRenderer.send('pet-shake');swings=[];}}direction=next;lastX=event.screenX;}}},true);
 // Pointer events carry no click count, so double clicks are counted here.
 document.addEventListener('pointerup',event=>{if(event.button!==0||!down)return;swallow(event);let clicks=0;if(!dragged){const now=Date.now();clicks=lastClick&&now-lastClick.at<500&&Math.abs(event.screenX-lastClick.x)+Math.abs(event.screenY-lastClick.y)<6?lastClick.clicks+1:1;lastClick={at:now,x:event.screenX,y:event.screenY,clicks};}else lastClick=null;finish(event,clicks||1);},true);
 document.addEventListener('pointercancel',event=>finish(event,0),true);
 root.addEventListener('lostpointercapture',event=>finish(event,0));
 window.addEventListener('blur',()=>finish(null,0));
 for(const type of ['mousedown','mouseup','click','dblclick'])document.addEventListener(type,event=>{if(event.button===0)swallow(event);},true);
 document.addEventListener('contextmenu',event=>{event.preventDefault();if(down)finish(event,0);ipcRenderer.send('pet-menu');},true);
});
