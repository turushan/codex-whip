// Deterministic marketing animation. No Codex process or session is read.
// Compile, create original sound, and encode: python3 scripts/render_demo.py
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 1280, height = 720, fps = 30
let duration = 56.0
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconURL = URL(fileURLWithPath: CommandLine.arguments[2])
let exampleMessage = CommandLine.arguments[3]
let retrySeconds = Int(CommandLine.arguments[4])!
let checkSeconds = Int(CommandLine.arguments[5])!
let avatarURL = URL(fileURLWithPath: CommandLine.arguments[6])
let retryMinutes = retrySeconds / 60
let retryLabel = retrySeconds % 60 == 0 ? "\(retryMinutes) \(retryMinutes == 1 ? "minute" : "minutes")" : "\(retrySeconds) seconds"
let checkMinutes = checkSeconds / 60
let checkLabel = checkSeconds % 60 == 0 ? "\(checkMinutes) \(checkMinutes == 1 ? "minute" : "minutes")" : "\(checkSeconds) seconds"
let retryTimer = String(format: "%d:%02d", retryMinutes, retrySeconds % 60)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let icon = NSImage(contentsOf: iconURL), let avatar = NSImage(contentsOf: avatarURL) else { fatalError("Missing approved artwork") }

func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}
let white = color(0xF0F7FF), secondary = color(0xA8BCD5), cyan = color(0x68D9EF)
let amber = color(0xF3C77D), red = color(0xFFA195), green = color(0x9EE0C3)
func clamp(_ x: Double) -> Double { max(0, min(1, x)) }
func smooth(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
func out(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * t }
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { point(mix(a.x, b.x, t), mix(a.y, b.y, t)) }
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ fill: NSColor, radius: CGFloat = 0) {
    let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
}
func stroke(_ a: CGPoint, _ b: CGPoint, _ fill: NSColor, width: CGFloat = 1) {
    let cg = NSGraphicsContext.current!.cgContext
    cg.setStrokeColor(fill.cgColor); cg.setLineWidth(width); cg.setLineCap(.round)
    cg.move(to: a); cg.addLine(to: b); cg.strokePath()
}
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
          _ fill: NSColor = white, weight: NSFont.Weight = .regular,
          isMono: Bool = false, width: CGFloat = 1100, height: CGFloat = 100) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
    let font = isMono ? NSFont(name: "Menlo-Regular", size: size)! : NSFont.systemFont(ofSize: size, weight: weight)
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes:
        [.font: font, .foregroundColor: fill, .paragraphStyle: paragraph])
}
func measure(_ value: String, size: CGFloat = 23) -> CGFloat {
    (value as NSString).size(withAttributes: [.font: NSFont(name: "Menlo-Regular", size: size)!]).width
}
func alpha(_ value: Double, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current!.cgContext.setAlpha(clamp(value)); body(); NSGraphicsContext.restoreGraphicsState()
}
func clipped(_ bounds: CGRect, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current!.cgContext.clip(to: bounds); body(); NSGraphicsContext.restoreGraphicsState()
}
func moved(_ x: CGFloat = 0, _ y: CGFloat, _ body: () -> Void) {
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current!.cgContext.translateBy(x: x, y: y); body(); NSGraphicsContext.restoreGraphicsState()
}

let whipBursts: [[Double]] = [[7.0, 8.8, 10.6], [28.0, 29.5, 31.0], [44.5, 46.0, 47.5]]
let sceneStarts = [0.0, 18.0, 35.0]
let submissions = [12.2, 32.3, 48.8]
let workStarts = [13.6, 33.4, 50.1]
let permissionTimes = [Double.infinity, 26.5, 43.0]
let words = exampleMessage.split(separator: " ").map(String.init)
precondition(words.count == 9, "The authored word groups expect the shared nine-word default message")
func sceneIndex(_ time: Double) -> Int { time < 18 ? 0 : (time < 35 ? 1 : 2) }

struct Caption {
    let start: Double; let headline: String; let subtitle: String; let status: String; let detail: String
}
let captions = [
    Caption(start: 0, headline: "Model at capacity.", subtitle: "Your unfinished work stays right where you left it.", status: "Capacity detected", detail: "Retry every \(retryLabel) · Same selected model"),
    Caption(start: 4.3, headline: "\(retryLabel) later", subtitle: "No model shopping. No starting over.", status: "Retry due", detail: "Waiting time compressed"),
    Caption(start: 6.0, headline: "A little encouragement.", subtitle: "One message. A very clear point.", status: "Preparing the retry", detail: "Typing illustrated · The app sends one message"),
    Caption(start: 12.2, headline: "Right back to it.", subtitle: "The same conversation. The same model.", status: "Retry sent", detail: "Continuing unfinished work · Monitoring recovery"),
    Caption(start: 18, headline: "Out of quota?", subtitle: "Whip knows how to wait, too.", status: "Waiting for quota", detail: "Automatic checks every \(checkLabel)"),
    Caption(start: 21, headline: "Go make a coffee.", subtitle: "Whip keeps checking while the unfinished work waits.", status: "Quota still unavailable", detail: "\(checkLabel) between checks · Time compressed"),
    Caption(start: 26.5, headline: "Your quota renews.", subtitle: "Codex confirms quota. Whip picks up the thread.", status: "Quota available", detail: "A scheduled renewal · Same selected model"),
    Caption(start: 32.3, headline: "Coffee is optional.", subtitle: "Getting back to work is automatic.", status: "Quota retry sent", detail: "Continuing unfinished work · Monitoring recovery"),
    Caption(start: 35, headline: "Or a reset comes early.", subtitle: "Sometimes the internet brings good news.", status: "Waiting for quota", detail: "Illustrated announcement · Quota checks continue"),
    Caption(start: 40.6, headline: "Whip keeps checking.", subtitle: "Early reset or regular renewal, the next check looks for quota.", status: "Waiting for the next quota check", detail: "Whip checks Codex for available quota"),
    Caption(start: 43, headline: "Quota confirmed.", subtitle: "Same model. Unfinished work, continued.", status: "Quota available", detail: "Confirmed by Codex · Same selected model"),
    Caption(start: 48.8, headline: "Back before you ask.", subtitle: "A little persistence goes a long way.", status: "Quota retry sent", detail: "Continuing unfinished work · Monitoring recovery")
]
func drawCaption(_ caption: Caption, time: Double) {
    text(caption.headline, 96, 120, caption.headline.count > 28 ? 49 : 57, weight: .semibold, height: 76)
    text(caption.subtitle, 98, 194, 23, secondary, height: 38)
    let available = sceneIndex(time) == 0 ? time >= 12.2 : time >= permissionTimes[sceneIndex(time)]
    rect(113, 638, 8, 8, available ? cyan : amber, radius: 4)
    let status = time >= 42 && time < 43 ? "Checking quota" : caption.status
    text(status, 135, 625, 23, weight: .medium, width: 800, height: 34)
    text(caption.detail, 135, 659, 18, secondary, width: 850, height: 28)
}
func drawInputWords(time: Double, scene: Int) -> CGFloat {
    let burst = whipBursts[scene]
    let reveals = [burst[0]+0.03, burst[0]+0.20, burst[1]+0.03, burst[1]+0.18, burst[1]+0.33,
                   burst[2]+0.03, burst[2]+0.16, burst[2]+0.29, burst[2]+0.42]
    var x: CGFloat = 160, caret: CGFloat = 160
    for (index, word) in words.enumerated() {
        let length = measure(word), visible = out((time - reveals[index]) / 0.18)
        if visible > 0 {
            clipped(CGRect(x: x-1, y: 536, width: (length+2)*visible, height: 35)) {
                text(word, x, 538, 23, isMono: true, width: length+3, height: 38)
            }
            caret = x + length*visible
        }
        x += length + measure(" ")
    }
    return caret
}
func checkPulse(_ time: Double, _ at: Double, center: CGPoint) {
    let progress = (time - at) / 1.1
    guard progress >= 0 && progress < 1 else { return }
    alpha(1-progress) {
        let radius = CGFloat(10 + progress*20)
        let path = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
        cyan.setStroke(); path.lineWidth = 2; path.stroke()
    }
}
func drawQuota(time: Double, scene: Int, historyScroll: CGFloat) {
    let check = permissionTimes[scene], confirmed = smooth((time-check)/0.55)
    let postPresence = scene == 2 ? smooth((time-35.6)/0.8)*(1-smooth((time-40.6)/0.6)) : 0
    let meterWidth = mix(720, 350, postPresence)
    text("•", 130, 308-historyScroll, 23, cyan, isMono: true, height: 40)
    text(scene == 1 ? "Checking the remaining shortcuts…" : "Continuing the shortcut changes…", 160, 310-historyScroll, 23, isMono: true, width: 990, height: 40)
    alpha(1-confirmed) {
        rect(130, 365-historyScroll, 6, 23, amber, radius: 3)
        text("Usage quota exhausted.", 154, 358-historyScroll, 23, amber, isMono: true, width: 450, height: 40)
        text(scene == 1 ? "Waiting for the next renewal." : "Waiting for available quota.", 154, 397-historyScroll, 21, secondary, isMono: true, width: 460, height: 38)
    }
    alpha(confirmed) {
        rect(130, 365-historyScroll, 6, 23, green, radius: 3)
        text("Quota is available again.", 154, 358-historyScroll, 23, green, isMono: true, height: 40)
        text("Confirmed by Codex. Ready to continue.", 154, 397-historyScroll, 21, secondary, isMono: true, height: 38)
    }
    rect(154, 453-historyScroll, meterWidth, 10, color(0x29394B), radius: 5)
    if confirmed > 0 { rect(154, 453-historyScroll, meterWidth*confirmed, 10, cyan, radius: 5) }
    let checks = scene == 1 ? [21.0,24.0,26.5] : [42.0,43.0]
    for tick in checks { checkPulse(time, tick, center: point(154,458-historyScroll)) }
    if time < check {
        let progress = scene == 1 ? clamp((time-18.8)/6.5) : clamp((time-35.8)/6.2)
        let x = 154 + meterWidth*CGFloat(progress)
        rect(x-3, 450-historyScroll, 6, 16, amber, radius: 3)
    }
}
func drawSceneConversation(time: Double, scene: Int) {
    let send = submissions[scene], work = workStarts[scene]
    let submission = smooth((time-send)/1.05)
    let outputScroll = smooth((time-(work+2.4))/1.4)*80
    let historyScroll = submission*135 + outputScroll
    clipped(CGRect(x:115,y:298,width:1052,height:207)) {
        if scene == 0 {
            text("›",130,308-historyScroll,24,cyan,isMono:true,height:40)
            text("Add keyboard shortcuts to the command palette.",160,310-historyScroll,23,isMono:true,width:990,height:40)
            rect(130,365-historyScroll,6,23,red,radius:3)
            text("Selected model is at capacity.",154,358-historyScroll,23,red,isMono:true,height:40)
            text("Please try a different model.",154,397-historyScroll,23,secondary,isMono:true,height:40)
        } else { drawQuota(time:time,scene:scene,historyScroll:historyScroll) }
    }
    if time >= send {
        let y = mix(538,335,submission)-outputScroll
        clipped(CGRect(x:115,y:298,width:1052,height:296)) {
            text("›",130,y-2,24,cyan,isMono:true,height:40)
            text(exampleMessage,160,y,23,isMono:true,width:975,height:40)
        }
    }
    let lines: [String] = scene == 0
        ? ["Inspecting the shortcut handlers…","Adding keys to existing actions…","Continuing with the selected model…"]
        : (scene == 1 ? ["Picking up the unfinished tests…","Checking the existing changes…","Continuing with the selected model…"]
           : ["Restoring the working context…","Continuing the shortcut changes…","Keeping the selected model…"])
    clipped(CGRect(x:115,y:298,width:1052,height:207)) {
        var caret = point(160,398), hasOutput = false
        for (index,value) in lines.enumerated() {
            let start = work+Double(index)*0.9
            if time < start { continue }
            let count = Int(Double(value.count)*clamp((time-start)/0.75))
            let visible = String(value.prefix(count)), y = CGFloat(398+index*40)-outputScroll
            text("•",130,y,23,cyan,isMono:true,height:35)
            text(visible,160,y,23,isMono:true,width:970,height:35)
            caret=point(160+measure(visible)+4,y+4);hasOutput=true
        }
        if hasOutput { rect(caret.x,caret.y,10,24,cyan.withAlphaComponent(0.52+0.36*(sin(time * .pi*2)+1)/2),radius:1) }
    }
}
func drawConversation(time: Double, scene: Int) {
    let start = sceneStarts[scene], progress = smooth((time-start)/0.8)
    if scene > 0 && progress < 1 {
        clipped(CGRect(x:115,y:298,width:1052,height:207)) {
            alpha(1-progress) { moved(0,-CGFloat(progress)*212) { drawSceneConversation(time:start-0.001,scene:scene-1) } }
            moved(0,CGFloat(1-progress)*212) { drawSceneConversation(time:time,scene:scene) }
        }
    } else { drawSceneConversation(time:time,scene:scene) }
}
func drawPost(time: Double) {
    guard time >= 35.6 && time <= 41.2 else { return }
    let entry = out((time-35.6)/0.8), exit=smooth((time-40.4)/0.8)
    let x=mix(1295,610,entry), y=mix(311,280,exit)
    alpha(entry*(1-exit)) {
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.4);shadow.shadowBlurRadius=20;shadow.shadowOffset=NSSize(width:0,height:9)
        NSGraphicsContext.saveGraphicsState();shadow.set();rect(x,y,548,178,color(0x152639),radius:16);NSGraphicsContext.restoreGraphicsState()
        let border=NSBezierPath(roundedRect:NSRect(x:x,y:y,width:548,height:178),xRadius:16,yRadius:16);color(0x466782).setStroke();border.lineWidth=1;border.stroke()
        NSGraphicsContext.saveGraphicsState();NSBezierPath(ovalIn:NSRect(x:x+22,y:y+20,width:56,height:56)).addClip()
        avatar.draw(in:NSRect(x:x+22,y:y+20,width:56,height:56),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil);NSGraphicsContext.restoreGraphicsState()
        text("Tibo",x+94,y+19,23,weight:.semibold,width:100,height:32)
        rect(x+148,y+24,16,16,color(0x2196EA),radius:8)
        stroke(point(x+152,y+32),point(x+155,y+35),white,width:1.6);stroke(point(x+155,y+35),point(x+161,y+28),white,width:1.6)
        text("@thsottiaux",x+94,y+50,17,secondary,width:250,height:25)
        text("Reset all propagated. Enjoy.",x+24,y+91,28,weight:.medium,width:500,height:43)
        text("Illustrated reset announcement",x+24,y+143,15,secondary,width:500,height:24)
    }
}

// A separate braided handle and flexible tapered lash. Every control point
// changes across wind-up, strike, follow-through and recoil.
struct WhipPose { let butt: CGPoint; let rope: [CGPoint] }
let idleWhip = WhipPose(butt: point(1142, 443), rope: [
    point(1107, 397), point(1058, 350), point(1119, 302), point(1172, 327),
    point(1234, 356), point(1210, 425), point(1156, 417), point(1106, 410), point(1116, 357), point(1160, 374)])
let woundWhip = WhipPose(butt: point(1150, 424), rope: [
    point(1112, 367), point(1050, 330), point(1045, 282), point(1118, 286),
    point(1205, 280), point(1218, 358), point(1154, 366), point(1094, 372), point(1080, 317), point(1124, 318)])
let strikeWhip = WhipPose(butt: point(1132, 420), rope: [
    point(1089, 456), point(1020, 418), point(1020, 335), point(1126, 336),
    point(1222, 337), point(1211, 448), point(1176, 496), point(1162, 518), point(1137, 537), point(1128, 551)])
let followWhip = WhipPose(butt: point(1151, 435), rope: [
    point(1105, 460), point(1050, 423), point(1065, 343), point(1152, 361),
    point(1222, 380), point(1215, 500), point(1142, 567), point(1113, 595), point(1088, 575), point(1104, 552)])
func mix(_ a: WhipPose, _ b: WhipPose, _ t: Double) -> WhipPose {
    WhipPose(butt: mix(a.butt, b.butt, t), rope: zip(a.rope, b.rope).map { mix($0, $1, t) })
}
func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return point(u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*d.x,
                 u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*d.y)
}
func drawWhip(time: Double) {
    guard let burst = whipBursts.first(where: { time >= $0[0] - 1.05 && time <= $0[2] + 1.2 }) else { return }
    let entry = out((time - (burst[0] - 1.05)) / 0.4)
    let exit = smooth((time - (burst[2] + 0.45)) / 0.75)
    var pose = idleWhip
    for impact in burst {
        let t = time - impact
        if t >= -0.7 && t < -0.3 { pose = mix(idleWhip, woundWhip, smooth((t + 0.7) / 0.4)) }
        else if t >= -0.3 && t < 0 { pose = mix(woundWhip, strikeWhip, pow((t + 0.3) / 0.3, 2)) }
        else if t >= 0 && t < 0.24 { pose = mix(strikeWhip, followWhip, out(t / 0.24)) }
        else if t >= 0.24 && t < 0.7 { pose = mix(followWhip, idleWhip, smooth((t - 0.24) / 0.46)) }
    }
    alpha(entry * (1 - exit)) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.cgContext.translateBy(x: (1 - entry) * 85 + exit * 85, y: 0)
        var samples: [CGPoint] = []
        for curve in 0..<3 {
            let i = curve * 3
            for step in 0..<45 { samples.append(cubic(pose.rope[i], pose.rope[i+1], pose.rope[i+2], pose.rope[i+3], CGFloat(step) / 44)) }
        }
        for index in 1..<samples.count {
            let fraction = CGFloat(index) / CGFloat(samples.count - 1)
            let thickness = 8.4 * pow(1 - fraction, 0.7) + 1.0
            stroke(samples[index-1], samples[index], color(0x39241D), width: thickness + 2)
            stroke(samples[index-1], samples[index], color(0xAD7744), width: thickness)
            stroke(point(samples[index-1].x - 0.7, samples[index-1].y - 0.6), point(samples[index].x - 0.7, samples[index].y - 0.6), color(0xD1A06B, 0.75), width: max(0.5, thickness * 0.25))
            if index % 5 == 0 && fraction < 0.8 {
                let delta = point(samples[index].x - samples[index-1].x, samples[index].y - samples[index-1].y)
                let length = max(0.001, hypot(delta.x, delta.y))
                let normal = point(-delta.y / length * thickness * 0.3, delta.x / length * thickness * 0.3)
                stroke(point(samples[index].x - normal.x, samples[index].y - normal.y), point(samples[index].x + normal.x, samples[index].y + normal.y), color(0x593821, 0.55), width: 1)
            }
        }
        let attachment = pose.rope[0]
        stroke(pose.butt, attachment, color(0x2F211B), width: 22)
        stroke(pose.butt, attachment, color(0x85512E), width: 17)
        stroke(point(pose.butt.x - 2, pose.butt.y), point(attachment.x - 2, attachment.y), color(0xC18B50), width: 4)
        for amount in stride(from: 0.16, through: 0.85, by: 0.13) {
            let center = mix(pose.butt, attachment, amount)
            let dx = attachment.x - pose.butt.x, dy = attachment.y - pose.butt.y, length = hypot(dx, dy)
            stroke(point(center.x + dy / length * 7, center.y - dx / length * 7), point(center.x - dy / length * 7, center.y + dx / length * 7), color(0x4E3020, 0.8), width: 2)
        }
        stroke(mix(pose.butt, attachment, 0.89), attachment, color(0xDFB46F), width: 19)
        stroke(pose.butt, mix(pose.butt, attachment, 0.07), color(0xB88950), width: 19)
        NSGraphicsContext.restoreGraphicsState()
    }
    for impact in burst {
        let progress = (time - impact) / 0.25
        if progress >= 0 && progress <= 1 {
            alpha(1 - progress) {
                let shift = CGFloat(progress) * 9
                stroke(point(1140 + shift, 538 - shift), point(1153 + shift, 528 - shift), cyan, width: 2.3)
                stroke(point(1147 + shift, 552), point(1164 + shift, 552), cyan, width: 2.3)
                stroke(point(1139 + shift, 565 + shift), point(1150 + shift, 576 + shift), cyan, width: 2.3)
                rect(1126, 549, 4, 4, white, radius: 2)
            }
        }
    }
}


func drawTerminal(time: Double) {
    let scene=sceneIndex(time),send=submissions[scene]
    NSGraphicsContext.saveGraphicsState()
    let outro=smooth((time-52)/1), scale=mix(1,0.82,outro)
    let cg=NSGraphicsContext.current!.cgContext
    cg.translateBy(x:640,y:423+CGFloat(outro)*64);cg.scaleBy(x:scale,y:scale);cg.translateBy(x:-640,y:-423)
    let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.32);shadow.shadowBlurRadius=28;shadow.shadowOffset=NSSize(width:0,height:10)
    NSGraphicsContext.saveGraphicsState();shadow.set();rect(96,244,1088,358,color(0x0B121D),radius:14);NSGraphicsContext.restoreGraphicsState()
    rect(96,244,1088,44,color(0x182536),radius:14);rect(96,266,1088,22,color(0x182536))
    stroke(point(96,288),point(1184,288),color(0x35475D,0.65))
    for(index,fill)in[color(0xE68D86),color(0xD8BC7A),color(0x87BCA3)].enumerated(){rect(CGFloat(116+index*23),260,12,12,fill,radius:6)}
    text("shortcuts · Codex",495,253,18,secondary,width:300,height:32)
    text("Selected model",1008,253,17,secondary,width:157,height:32)
    rect(97,512,1086,89,color(0x101D2C),radius:13);rect(97,512,1086,43,color(0x101D2C))
    stroke(point(97,512),point(1183,512),color(0x40546B))
    let labelAlpha=time<send ? 1-smooth((time-(send-0.35))/0.25) : smooth((time-(send+0.45))/0.3)
    alpha(labelAlpha){text("Example saved message",130,516,14,secondary,height:24)}
    drawConversation(time:time,scene:scene)
    let caretAlpha=0.45+0.35*(sin(time * .pi*2)+1)/2
    if time < send {
        text("›",130,536,24,cyan,isMono:true,height:40)
        let caret=drawInputWords(time:time,scene:scene);rect(caret+4,542,10,24,cyan.withAlphaComponent(caretAlpha),radius:1)
    }else{
        alpha(smooth((time-(send+0.48))/0.25)){text("›",130,536,24,cyan,isMono:true,height:40);rect(164,542,10,24,cyan.withAlphaComponent(caretAlpha),radius:1)}
    }
    drawPost(time:time)
    drawWhip(time:time)
    NSGraphicsContext.restoreGraphicsState()
}
func render(time: Double) -> CGImage {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32)!
    let cg=NSGraphicsContext(bitmapImageRep:bitmap)!.cgContext
    NSGraphicsContext.saveGraphicsState();cg.translateBy(x:0,y:CGFloat(height));cg.scaleBy(x:1,y:-1)
    NSGraphicsContext.current=NSGraphicsContext(cgContext:cg,flipped:true)
    NSGradient(starting:color(0x081523),ending:color(0x0D2641))!.draw(in:NSRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)),angle:90)
    for x in stride(from:CGFloat(32),through:CGFloat(width),by:48){stroke(point(x,0),point(x,CGFloat(height)),color(0x5DBBEE,0.07))}
    for y in stride(from:CGFloat(0),through:CGFloat(height),by:48){stroke(point(0,y),point(CGFloat(width),y),color(0x5DBBEE,0.07))}
    icon.draw(in:NSRect(x:93,y:36,width:64,height:64),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    text("Codex Whip",174,53,27,weight:.semibold,height:44)
    text("Animated demo · typing illustrated",790,44,19,secondary,width:400,height:30)
    text("Time compressed · Sound on in the MP4",790,73,17,secondary,width:400,height:27)
    let outro=smooth((time-52)/0.65)
    alpha(1-outro){
        let current=captions.lastIndex(where:{time >= $0.start}) ?? 0,elapsed=time-captions[current].start
        if current>0 && elapsed<0.35 {
            let progress=smooth(elapsed/0.35)
            alpha(1-progress){drawCaption(captions[current-1],time:time)}
            alpha(progress){drawCaption(captions[current],time:time)}
        }else{drawCaption(captions[current],time:time)}
        stroke(point(96,620),point(1184,620),color(0x5DBBEE,0.27))
        let active=sceneIndex(time)
        text(["Capacity","Quota renewal","Early reset"][active],996,626,18,secondary,width:190,height:28)
        for i in 0..<3 {rect(CGFloat(998+i*62),666,48,4,i<=active ? cyan : color(0x36516A),radius:2)}
        if time < 4.3 {alpha(1-smooth((time-3.9)/0.35)){text("Retry in \(retryTimer)",960,590,17,secondary,isMono:true,width:225,height:28)}}
    }
    drawTerminal(time:time)
    alpha(out((time-52.1)/0.75)){
        text("Same model. Keep going.",96,126,67,weight:.semibold,height:90)
        text("Capacity. Renewals. Early resets. One persistent little Mac app.",99,217,25,secondary,height:42)
        text("github.com/turushan/codex-whip",98,651,22,cyan,height:35)
        text("Unofficial Codex CLI companion",798,655,17,secondary,width:390,height:30)
    }
    NSGraphicsContext.restoreGraphicsState();return bitmap.cgImage!
}
let origin="Codex Whip programmatic three-story marketing demo; typing illustrated and time compressed. Capacity, scheduled quota renewal and illustrative early-reset announcement. Native AppKit/CoreGraphics renderer. Existing approved app icon and unmodified public Tibo avatar from https://codex-resets.com/thsottiaux-avatar.jpg; source assets/demo/tibo-avatar.provenance.json. Actual app checks Codex quota, not social posts; one local RPC continuation. No live session data, model requests or endorsement."
let metadata:[CFString:Any]=[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGTitle:"Codex Whip · three ways to keep going",kCGImagePropertyPNGAuthor:"Codex Whip",kCGImagePropertyPNGDescription:origin,kCGImagePropertyPNGSoftware:"Native AppKit/CoreGraphics deterministic renderer"]]
func save(_ image:CGImage,to url:URL){
    let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,image,metadata as CFDictionary);precondition(CGImageDestinationFinalize(destination))
}
if let index=CommandLine.arguments.firstIndex(of:"--preview"),CommandLine.arguments.indices.contains(index+1),let instant=Double(CommandLine.arguments[index+1]) {
    save(render(time:instant),to:output.appendingPathComponent("preview.png"))
}else{
    for frame in 0..<Int(duration*Double(fps)){
        autoreleasepool{save(render(time:Double(frame)/Double(fps)),to:output.appendingPathComponent(String(format:"frame-%04d.png",frame)))}
    }
    save(render(time:54),to:output.appendingPathComponent("poster.png"))
    print("Rendered \(Int(duration*Double(fps))) deterministic frames and poster at1280×720.")
}
