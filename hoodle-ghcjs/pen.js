function toSVGPointArray(svg,xys) {
    var ctm = svg.screenCTM();
    var xys_canvas = xys.map( function(xy) {
        var x = xy[0];
        var y = xy[1];
        var pt = (new SVG.Point(x,y)).transform(ctm.inverse());
        return [pt.x, pt.y];
    });
    var arr = new SVG.PointArray(xys_canvas);
    return arr;
}

function drawPath(svg,xys) {
    var path = svg.polyline(xys).fill("none").stroke({width:0.2, color:'#f06'});
}


function preventDefaultTouchMove() {
  document.body.addEventListener("touchmove", function(e){e.preventDefault()}, { passive: false, useCapture: false });
}

var dpi = window.devicePixelRatio;

function fix_dpi(canvas) {
    //get CSS height
    //the + prefix casts it to an integer
    //the slice method gets rid of "px"
    let style_height = +getComputedStyle(canvas).getPropertyValue("height").slice(0, -2);
    //get CSS width
    let style_width = +getComputedStyle(canvas).getPropertyValue("width").slice(0, -2);
    //scale the canvas
    canvas.setAttribute('height', style_height * dpi);
    canvas.setAttribute('width', style_width * dpi);
}

var canvas = document.getElementById("overlay");
var context = canvas.getContext("2d");


console.log(dpi);
var offcanvas = document.createElement("canvas");

fix_dpi(canvas);

offcanvas.width = canvas.width;
offcanvas.height = canvas.height;
var offcontext = offcanvas.getContext("2d");

console.log("canvas:" + canvas.width + "," + canvas.height);
console.log("offcanvas:" + offcanvas.width + "," + offcanvas.height);

function refresh() {
    context.clearRect(0,0,canvas.width,canvas.height);
    context.drawImage(offcanvas,0,0);
}

function overlay_point(x0,y0,x1,y1) {
    var rect = canvas.getBoundingClientRect();
    var scaleX = canvas.width / rect.width;
    var scaleY = canvas.height / rect.height;

    var cx0 = (x0 - rect.left)*scaleX;
    var cy0 = (y0 - rect.top)*scaleY;
    var cx1 = (x1 - rect.left)*scaleX;
    var cy1 = (y1 - rect.top)*scaleY;

    offcontext.beginPath();
    offcontext.strokeStyle = '#003300';
    offcontext.moveTo(cx0,cy0);
    offcontext.lineTo(cx1,cy1);
    offcontext.stroke();
}

function clear_overlay() {
    offcontext.clearRect(0,0,offcanvas.width,offcanvas.height);
}

// GHCJS start
h$main(h$mainZCMainzimain);
