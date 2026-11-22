import AppKit
import Foundation
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

/// Exercises the command/value boundaries actually used by the inspector. The binding and optics
/// metadata come from the opened RAW. Scheduling a second preview belongs to the rendering benchmark.
@MainActor final class PhotoWorkflowBenchmark {
    struct Case {
        let id, boundary, input: String
        let distinct: Bool
    }

    struct Reading { var values: [Double] = []; var text = "" }
    private struct Rejected: LocalizedError {
        let errorDescription: String?
        init(_ value: String) { errorDescription = value }
    }
    private final class Draft { var recipe: DevelopmentRecipe; init(_ recipe: DevelopmentRecipe) { self.recipe = recipe } }
    private let facts: DevelopmentSourceFacts, sourceHash: String, generation: UInt64
    private let baseline: DevelopmentAdjustmentsV3, defaults: UserDefaults
    private let draft: Draft, session: EditingDevelopmentSession, store: DevelopmentLensProfileDefaultsStore
    private var context: EditingInteractionContext!
    private var failure: Error?
    private var event: (DevelopmentAdjustmentID) -> EditingCommandEvent {
        { group in .init(context: self.context, control: .init(group: group, name: "检查器基准")) }
    }
    private var optics: PhotosOpticsControls {
        .init(session: session, profileDefaults: store, context: context, onError: { self.failure = $0 },
              onPicker: { _ in }, lensMetadata: facts.lensMetadata)
    }

    init(facts: DevelopmentSourceFacts, raw: String, generation: UInt64, baseline: DevelopmentAdjustmentsV3,
         defaults: UserDefaults) {
        self.facts = facts; sourceHash = raw; self.generation = generation; self.baseline = baseline; self.defaults = defaults
        let draft = Draft(.init(adjustmentsV3: baseline)); self.draft = draft
        session = EditingDevelopmentSession(readRecipe: { draft.recipe }, commitRecipe: { next, _ in draft.recipe = next })
        store = DevelopmentLensProfileDefaultsStore(defaults: defaults)
    }

    static let cases: [Case] = [
        .init(id:"light-histogram-drag",boundary:"histogram zone and drag delta to committed gesture recipe",input:"exposure zone +20 / −20 pixels over a 250-pixel axis",distinct:true),
        .init(id:"light-numeric-reset",boundary:"existing scalar command and session commit to reset value",input:"clear an edited exposure from +0.3 / −0.6 EV-param",distinct:false),
        .init(id:"curve-input-output",boundary:"original point-number rows to validated edited recipe",input:"edit the middle red knot input/output to (0.28,0.38) / (0.64,0.72)",distinct:true),
        .init(id:"curve-reset-channel",boundary:"selected curve channel reset action to committed recipe",input:"reset the red / blue channel; preserve all other channels",distinct:true),
        .init(id:"curve-keyboard",boundary:"oriented native keyDown on the original AppKit curve editor to applied knot",input:"middle control point, Left / Shift-Right",distinct:true),
        .init(id:"curve-parametric",boundary:"parametric panel recipe to the 121 transfer-function ordinates drawn by its actual inspector plot",input:"existing RAW tone curve with highlights +35 / −35",distinct:true),
        .init(id:"mixer-hsl-mode",boundary:"selected HSL organization to the eight actual Photos inspector row values, labels and ranges",input:"Hue / Saturation organization",distinct:true),
        .init(id:"mixer-color-mode",boundary:"selected Color slot to the three original H/S/L row values and ranges",input:"select red / blue in a recipe with distinct saved slider values",distinct:true),
        .init(id:"mixer-eight-colors",boundary:"original visible HSL row command to committed eight-slot recipe",input:"choose cyan / magenta and change only that slot's hue",distinct:true),
        .init(id:"optics-profile-match",boundary:"actual EXIF match button action to selected lens recipe",input:"select matched Sony FE 14mm F1.8 GM over two different previous profiles",distinct:false),
        .init(id:"optics-profile-select",boundary:"catalog lookup and original lens profile selection action to committed recipe",input:"select generic-wide / generic-standard",distinct:true),
        .init(id:"optics-profile-defaults",boundary:"save / restore profile defaults and read back from independently opened preference store",input:"saved 0.8 / 0.65 values versus reset built-in 1 / 1",distinct:true),
    ]

    func prepare(_ id: String, state: Int) throws {
        var p = baseline
        switch id {
        case "light-numeric-reset": p.light = .init(enabled:true,exposure: state == 0 ? 0.3 : -0.6)
        case "curve-input-output", "curve-reset-channel", "curve-keyboard":
            let three = DevelopmentCurve(points: [.init(x:0,y:0),.init(x:0.45,y:0.57),.init(x:1,y:1)])
            p.curves.enabled = true; p.curves.red.curve = three; p.curves.blue.curve = three
        case "curve-parametric": p.curves.enabled = true; p.curves.parametric = .init(highlights:state == 0 ? 35 : -35)
        case "mixer-hsl-mode", "mixer-color-mode", "mixer-eight-colors":
            p.selectiveColor.enabled = true
            p.selectiveColor.colors = DevelopmentSelectiveColorSlotV3.allCases.enumerated().map { index, slot in
                var c = DevelopmentSelectiveColorAdjustmentV3(slot:slot)
                c.hue=Double(index); c.saturation=Double(index)*2; c.luminance=Double(index)*3
                return c
            }
        case "optics-profile-match", "optics-profile-defaults":
            guard let profile = DevelopmentLensProfileCatalogV3.profile(id: id == "optics-profile-defaults" || state == 0 ? "generic-wide" : "generic-standard") else { throw Rejected("Missing initial profile") }
            var opt = PhotosOpticsProfileSelection.applying(profile,to:.init(),defaults:store)
            opt.profileDistortionAmount = 0.8; opt.profileVignettingAmount = 0.65; p.optics = opt
        default: break
        }
        draft.recipe = DevelopmentRecipe(adjustmentsV3:p); failure = nil
        context = try session.activate(workID:"workflow",admissionFingerprint:sourceHash,source:facts.sourceBinding,
                                       sourceGeneration:generation,noiseReduction:.raw)
    }

    func perform(_ id: String, state: Int) throws -> Reading {
        let initial = session.parameters
        switch id {
        case "light-histogram-drag":
            let width = 250.0, zone = PhotosHistogramZone.at(0.5)
            let token = try session.beginGesture(.init(group:.light,name:"直方图"),context:context)
            let command = try zone.dragCommand(origin:initial.light[keyPath:zone.path],delta:state == 0 ? 20 : -20,width:width,session:session)
            try session.apply(command,event:event(.light),gesture:token); try session.endGesture(token,.commit)
            let target = session.parameters.light[keyPath:zone.path]
            guard zone == .exposure, target != initial.light.exposure else { throw Rejected("Histogram drag produced no exposure change") }
            return .init(values:[target])
        case "light-numeric-reset":
            guard let field = PhotosScalarField.fields(for:.light,noiseReduction:.raw).first(where:{$0.id=="exposure"}) else { throw Rejected("Missing scalar field") }
            let command = try PhotosAdjustmentCommands.scalar(field,group:.light,value:0,parameters:initial,noiseReduction:.raw)
            try session.apply(command,event:event(.light))
            guard initial.light.exposure != 0, session.parameters.light.exposure == 0 else { throw Rejected("Scalar reset failed") }
            return .init(values:[session.parameters.light.exposure])
        case "curve-input-output":
            let pane = PhotosCurveParameterControls(session:session,context:context,onError:{self.failure=$0})
            let positions = state == 0 ? (0.28,0.38) : (0.64,0.72)
            for (isInput,number) in [(true,positions.0),(false,positions.1)] {
                let row = pane.pointRow(isInput ? "输入" : "输出",value:0.5,range:0...1,coordinate:isInput,channelPath:\.red,index:1)
                try session.apply(try row.command(number),event:event(.curves))
            }
            let point = session.parameters.curves.red.curve.points[1]
            guard point.x == positions.0, point.y == positions.1 else { throw Rejected("Curve coordinates differ") }
            return .init(values:[point.x,point.y])
        case "curve-reset-channel":
            let channel: DevelopmentCurveChannel = state == 0 ? .red : .blue
            let next = try PhotosCurveParameterControls.resetting(initial.curves,channel:channel)
            try session.apply(.setParameters(.curves(next)),event:event(.curves))
            let c = session.parameters.curves
            guard (state==0 ? c.red : c.blue) == .init(), (state==0 ? c.blue : c.red) == initial.curves.red else { throw Rejected("Channel reset affected wrong channel") }
            return .init(values:[Double(c.red.curve.points.count),Double(c.blue.curve.points.count)])
        case "curve-keyboard":
            let field = DevelopmentCurveControl(frame:.init(x:0,y:0,width:240,height:160))
            field.curve=initial.curves.red.curve; field.selected=1; field.selectionActive=true
            field.onChange={ c in
                do { var p=self.session.parameters.curves; p.red.curve=c; try self.session.apply(.setParameters(.curves(p)),event:self.event(.curves)) }
                catch { self.failure=error }
            }
            guard let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:state==0 ? [] : .shift,timestamp:0,
                windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:state==0 ? 123 : 124) else { throw Rejected("No native key event") }
            field.keyDown(with:key); if let failure { throw failure }
            let point = session.parameters.curves.red.curve.points[1]
            guard point != initial.curves.red.curve.points[1] else { throw Rejected("Original curve handler did not change selected point") }
            return .init(values:[point.x,point.y])
        case "curve-parametric":
            guard let model = initial.curves.parametric else { throw Rejected("No parametric plot model") }
            var values: [Double] = []
            try model.pointCurve().forEachInspectorPlotSample { values.append($0.y) }
            guard values.count == 121, values.allSatisfy(\.isFinite) else { throw Rejected("Missing parametric curve plot") }
            return .init(values:values)
        case "mixer-hsl-mode", "mixer-color-mode", "mixer-eight-colors":
            let pane = PhotosSelectiveColorControls(session:session,context:context,onError:{self.failure=$0})
            if id == "mixer-hsl-mode" {
                let mode: PhotosMixerOrganization = state == 0 ? .hue : .saturation
                let rows = DevelopmentSelectiveColorSlotV3.allCases.map { pane.organizedRow(mode,slot:$0) }
                guard rows.count == 8, Set(rows.map(\.name)).count == 8, rows.allSatisfy({$0.range == mode.range}) else { throw Rejected("Wrong HSL row organization") }
                return .init(values:rows.map(\.value),text:rows.map(\.name).joined(separator:" / "))
            }
            if id == "mixer-color-mode" {
                guard let color = initial.selectiveColor.colors.first(where:{$0.slot==(state == 0 ? .red : .blue)}) else { throw Rejected("Unknown selected color") }
                let rows = [PhotosMixerOrganization.hue,.saturation,.luminance].map { pane.colorRow($0,color:color) }
                guard rows.map(\.value) == [color.hue,color.saturation,color.luminance] else { throw Rejected("Wrong color slot readouts") }
                return .init(values:rows.map(\.value),text:rows.map(\.name).joined(separator:" / "))
            }
            let chosen: DevelopmentSelectiveColorSlotV3 = state == 0 ? .cyan : .magenta
            let row = pane.organizedRow(.hue,slot:chosen)
            try session.apply(try row.command(35),event:event(.selectiveColor))
            let all = session.parameters.selectiveColor.colors
            guard all.count == 8, all.first(where:{$0.slot==chosen})?.hue == 35,
                  all.filter({$0.slot != chosen}) == initial.selectiveColor.colors.filter({$0.slot != chosen}) else { throw Rejected("HSL slot edit changed neighbors") }
            return .init(values:all.map(\.hue))
        case "optics-profile-match":
            optics.matchMetadata()
            if let failure { throw failure }
            guard let lens = session.parameters.optics?.lensProfile, lens.id != initial.optics?.lensProfile?.id,
                  lens.model == facts.lensMetadata?.lensModel else { throw Rejected("This source EXIF has no matching catalog selection") }
            return .init(values:[lens.distortion,lens.vignetting],text:lens.id)
        case "optics-profile-select":
            guard let wanted = DevelopmentLensProfileCatalogV3.profile(id:state==0 ? "generic-wide" : "generic-standard") else { throw Rejected("Unknown lens profile") }
            optics.select(wanted); if let failure { throw failure }
            guard session.parameters.optics?.lensProfile == wanted else { throw Rejected("Profile selection did not commit") }
            return .init(values:[wanted.distortion,wanted.vignetting],text:wanted.id)
        default:
            guard let profile = initial.optics?.lensProfile else { throw Rejected("Missing lens profile") }
            if state == 0 { optics.saveProfileDefaults() } else { optics.resetProfileDefaults() }
            if let failure { throw failure }
            let reopened = DevelopmentLensProfileDefaultsStore(defaults:defaults).value(for:profile)
            guard reopened.distortion == (state == 0 ? 0.8 : 1), reopened.vignetting == (state == 0 ? 0.65 : 1) else { throw Rejected("Lens preference persistence failed") }
            return .init(values:[reopened.distortion,reopened.vignetting],text:profile.id)
        }
    }
}
