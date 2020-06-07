var isDrawing = false;

function getCanvasCoord(cvs,e) {
    var rect = cvs.getBoundingClientRect();
    var scaleX = canvas.width / rect.width;
    var scaleY = canvas.height / rect.height;
    return { x: (e.clientX - rect.left)*scaleX, y: (e.clientY - rect.top)*scaleY };
}

function startLineBit(cvs, ctxt, e) {
    var p = getCanvasCoord(cvs,e);
    ctxt.strokeStyle = "#ff0000";
    ctxt.moveTo(p.x,p.y);
}

function drawLineBit(cvs, ctxt, e) {
    var p = getCanvasCoord(cvs,e);
    ctxt.lineTo(p.x,p.y);
}

function endLineBit(cvs, ctxt, e) {
    var p = getCanvasCoord(cvs,e);
    ctxt.lineTo(p.x,p.y);
    ctxt.stroke();
}


function onPointerDown(e) {
    isDrawing = true;
    console.log("on pointerdown");
    startLineBit(canvas,context2,e);
}

function onPointerUp(e) {
    isDrawing = false;
    console.log("on pointerup");
    endLineBit(canvas,context2,e);
}

function onPointerMove(e) {
    if (isDrawing) {
        drawLineBit(canvas,context2,e);
    }
}

var canvas = document.getElementById("box");
var context = canvas.getContext("2d");

document.body.addEventListener("touchmove", function(e){e.preventDefault()}, { passive: false, useCapture: false });

canvas.width = 1280;
canvas.height = 1024;
canvas.addEventListener("pointerdown", onPointerDown);
canvas.addEventListener("pointerup"  , onPointerUp);
canvas.addEventListener("pointermove", onPointerMove);

var canvas1 = document.createElement("canvas");
canvas1.width = 1280;
canvas1.height = 1024;
var context1 = canvas1.getContext("2d");

var background = new Image();
background.src = "https://upload.wikimedia.org/wikipedia/commons/d/d3/BG_1280x1024.jpg";
background.onload = function() {
    context1.drawImage(background,0,0);
};

var canvas2 = document.createElement("canvas");
canvas2.width = 1280;
canvas2.height = 1024;
var context2 = canvas2.getContext("2d");

var n = 0;
var start = null;
function step(timestamp) {
    if(!start) start = timestamp;
    var progress = timestamp - start;
    var x = 640* Math.sin (progress / 10000);
    context.fillStyle = '#ffffff';
    context.fillRect(0,0,canvas.width,canvas.height);
    context.drawImage(canvas1,x,0);
    context.drawImage(canvas2,0,0);
    window.requestAnimationFrame(step);
}

window.requestAnimationFrame(step);

console.log ("pen.js is loaded");
