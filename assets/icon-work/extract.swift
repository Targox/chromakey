import Cocoa
let folder = URL(fileURLWithPath:CommandLine.arguments[1])
for (name,path) in [("passwords","/System/Applications/Passwords.app"),("chrome","/Applications/Google Chrome.app")] {
 let icon = NSWorkspace.shared.icon(forFile:path)
 let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
 icon.draw(in:NSRect(x:0,y:0,width:1024,height:1024),from:.zero,operation:.copy,fraction:1)
 NSGraphicsContext.restoreGraphicsState()
 try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name+"-1024.png"))
}
