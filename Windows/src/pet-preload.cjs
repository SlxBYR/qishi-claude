'use strict';
const {ipcRenderer}=require('electron');
window.addEventListener('DOMContentLoaded',()=>{let down=null,dragged=false,lastX=0,direction=0,swings=[];
 document.addEventListener('mousedown',event=>{if(event.button!==0)return;event.preventDefault();event.stopImmediatePropagation();down={x:event.screenX,y:event.screenY};dragged=false;lastX=event.screenX;direction=0;swings=[];ipcRenderer.send('pet-down',down);},true);
 document.addEventListener('mousemove',event=>{if(!down)return;event.preventDefault();if(!dragged&&Math.abs(event.screenX-down.x)+Math.abs(event.screenY-down.y)>3)dragged=true;if(dragged){ipcRenderer.send('pet-drag',{x:event.screenX,y:event.screenY});const d=event.screenX-lastX;if(Math.abs(d)>18){const next=Math.sign(d);if(direction&&next!==direction){swings=swings.filter(t=>Date.now()-t<900);swings.push(Date.now());if(swings.length>=2){ipcRenderer.send('pet-shake');swings=[];}}direction=next;lastX=event.screenX;}}},true);
 document.addEventListener('mouseup',event=>{if(event.button!==0||!down)return;event.preventDefault();event.stopImmediatePropagation();ipcRenderer.send('pet-up',{dragged,x:event.clientX,y:event.clientY,clicks:event.detail});down=null;},true);
 document.addEventListener('contextmenu',event=>{event.preventDefault();ipcRenderer.send('pet-menu');},true);
});
