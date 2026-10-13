import AppKit
let size=1024
let space=CGColorSpaceCreateDeviceRGB()
let ctx=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->CGColor { CGColor(red:r,green:g,blue:b,alpha:1) }
let gradient=CGGradient(colorsSpace:space,colors:[color(1,0.90,0.56),color(0.94,0.65,0.15)] as CFArray,locations:[0,1])!
func background() { ctx.drawLinearGradient(gradient,start:CGPoint(x:512,y:1024),end:CGPoint(x:512,y:0),options:[]) }
background()
ctx.setFillColor(color(0.22,0.17,0.08))
ctx.addPath(CGPath(roundedRect:CGRect(x:255,y:245,width:145,height:540),cornerWidth:72.5,cornerHeight:72.5,transform:nil));ctx.fillPath()
ctx.fillEllipse(in:CGRect(x:298,y:231,width:458,height:458))
ctx.saveGState()
ctx.beginPath();ctx.move(to:CGPoint(x:455,y:585));ctx.addLine(to:CGPoint(x:630,y:472));ctx.addLine(to:CGPoint(x:455,y:355));ctx.closePath();ctx.clip();background();ctx.restoreGState()
let image=ctx.makeImage()!
let rep=NSBitmapImageRep(cgImage:image)
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
