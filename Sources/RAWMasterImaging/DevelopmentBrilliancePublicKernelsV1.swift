enum Kernels {
    static let mono = """
    kernel vec4 chartGuide(__sample guide) {
        return vec4(clamp(dot(guide.rgb, vec3(0.3333)), 0.0, 1.0), 0.0, 0.0, 1.0);
    }
    """

    static let combine = """
    kernel vec4 chartGuideAndMap(__sample guide, __sample blurred, __sample map) {
        return vec4(guide.r, blurred.r, map.r, map.g);
    }
    """

    static let joint = """
    kernel vec4 chartJointMap(sampler combined, vec4 settings) {
        vec2 center = samplerCoord(combined);
        vec2 step = samplerTransform(combined, destCoord() + vec2(1.0)) - center;
        vec4 reference = sample(combined, center);
        vec2 sumMap = vec2(0.0);
        float sum = 0.0;
        for (float x = -2.0; x <= 2.0; x++) {
            for (float y = -2.0; y <= 2.0; y++) {
                vec2 offset = vec2(x, y) * settings.zw;
                float spatial = exp(-((x * x) + (y * y)) * settings.y);
                vec4 near = sample(combined, center + offset * step);
                float difference = near.g - reference.r;
                float luma = exp(-(difference * difference) * settings.x);
                sum += luma * spatial;
                sumMap += (luma * spatial) * near.ba;
            }
        }
        return vec4(sum < 0.001 ? reference.ba : sumMap / sum, 0.0, 1.0);
    }
    """

    static let reduce4 = """
    kernel vec4 chartReduce4(sampler source, vec4 settings) {
        vec2 center = destCoord() * settings.xy;
        vec4 result = sample(source, samplerTransform(source, center)) * 0.2491057;
        vec2 offset = 1.950197 * settings.zw;
        result += (sample(source, samplerTransform(source, center - offset))
                 + sample(source, samplerTransform(source, center + offset))) * 0.2049953;
        offset = 3.90137 * settings.zw;
        result += (sample(source, samplerTransform(source, center - offset))
                 + sample(source, samplerTransform(source, center + offset))) * 0.1142297;
        offset = 5.858401 * settings.zw;
        result += (sample(source, samplerTransform(source, center - offset))
                 + sample(source, samplerTransform(source, center + offset))) * 0.04335520;
        offset = 7.868863 * settings.zw;
        result += (sample(source, samplerTransform(source, center - offset))
                 + sample(source, samplerTransform(source, center + offset))) * 0.01286697;
        return result;
    }
    """

    static let reduce2 = """
    kernel vec4 chartReduce2(sampler source, vec4 settings) {
        vec2 center = destCoord() * settings.xy;
        vec2 innerOffset = 1.846239 * settings.zw;
        vec2 outerOffset = 3.745181 * settings.zw;
        vec4 outer = sample(source, samplerTransform(source, center - outerOffset));
        vec4 inner = sample(source, samplerTransform(source, center - innerOffset));
        vec4 middle = sample(source, samplerTransform(source, center));
        inner += sample(source, samplerTransform(source, center + innerOffset));
        outer += sample(source, samplerTransform(source, center + outerOffset));
        return ((0.4322908 * middle) + (0.2406165 * inner)) + (0.04323813 * outer);
    }
    """

    static let blur11 = """
    kernel vec4 chartResidualX(sampler source, vec4 offsets, vec4 outerOffset, vec4 weight) {
        vec2 center = destCoord();
        vec4 outerNegative = sample(source, samplerTransform(source, center - outerOffset.xy));
        vec4 middleNegative = sample(source, samplerTransform(source, center - offsets.zw));
        vec4 innerNegative = sample(source, samplerTransform(source, center - offsets.xy));
        vec4 innerPositive = sample(source, samplerTransform(source, center + offsets.xy));
        vec4 middlePositive = sample(source, samplerTransform(source, center + offsets.zw));
        vec4 outerPositive = sample(source, samplerTransform(source, center + outerOffset.xy));
        return ((weight.x * (innerNegative + innerPositive)) + (weight.y * (middleNegative + middlePositive)))
                + (weight.z * (outerNegative + outerPositive));
    }
    """

    static let blur7 = """
    kernel vec4 chartResidualY(sampler source, vec4 offsets, vec2 weight) {
        vec2 center = destCoord();
        vec4 outerNegative = sample(source, samplerTransform(source, center - offsets.zw));
        vec4 innerNegative = sample(source, samplerTransform(source, center - offsets.xy));
        vec4 innerPositive = sample(source, samplerTransform(source, center + offsets.xy));
        vec4 outerPositive = sample(source, samplerTransform(source, center + offsets.zw));
        return (weight.x * (innerNegative + innerPositive)) + (weight.y * (outerNegative + outerPositive));
    }
    """

    static let restore = """
    kernel vec4 chartRestore(sampler source, vec2 inverseScale) {
        vec2 coordinate = (inverseScale * destCoord()) - 0.5;
        vec2 cell = floor(coordinate);
        vec2 left = (cell - coordinate) + 1.0;
        vec2 right = coordinate - cell;
        vec2 leftWeight = ((((((-1.0 / 3.0) * left) * left) * left)
            + ((0.5 * left) * left)) + (0.5 * left)) + (1.0 / 6.0);
        vec2 rightWeight = 1.0 - leftWeight;
        vec2 first = ((((((((-0.5 * left) * left) * left)
            + ((0.5 * left) * left)) + (0.5 * left)) + (1.0 / 6.0)) / leftWeight) + cell) - 0.5;
        vec2 second = (((((right * right) * right) / 6.0) / rightWeight) + cell) + 1.5;
        vec4 sum = (leftWeight.x * leftWeight.y)
            * sample(source, samplerTransform(source, vec2(first.x, first.y)));
        sum += (rightWeight.x * leftWeight.y)
            * sample(source, samplerTransform(source, vec2(second.x, first.y)));
        sum += (leftWeight.x * rightWeight.y)
            * sample(source, samplerTransform(source, vec2(first.x, second.y)));
        sum += (rightWeight.x * rightWeight.y)
            * sample(source, samplerTransform(source, vec2(second.x, second.y)));
        return sum;
    }
    """

    static let poly = """
    kernel vec4 chartPoly(__sample srcPixel, __sample adjustment, float strength) {
        vec3 negative = min(srcPixel.rgb, 0.0);
        vec3 excess = max(srcPixel.rgb, 1.0) - 1.0;
        vec3 rgb = clamp(srcPixel.rgb, 0.0, 1.0);
        float luma = sqrt(dot(rgb, vec3(0.3333300)));
        float t = mix(0.0, (3.400 * adjustment.r) - 1.200, strength);
        vec3 gain = t > 0.0 ? vec3(1.500 * t) : vec3(1.750 * t, 1.750 * t, 1.550 * t);
        rgb = ((rgb * rgb) * gain) + (rgb * (1.0 - gain));
        rgb = sqrt(clamp(rgb, 0.0, 1.0));
        float middle = min(strength, 0.5);
        luma = luma * (1.0 - luma);
        float pivot = max(adjustment.g, 0.5);
        float a = middle * luma;
        float b = (-pivot) * a;
        vec3 target = ((((rgb.r * vec3(0.299 * a)) + (rgb.g * vec3(0.587 * a)))
            + (rgb.b * vec3(0.114 * a))) + rgb) + vec3(b);
        rgb = mix(rgb, vec3(pivot), (-luma) * middle);
        rgb = max(mix(rgb, target, 0.8), 0.0);
        rgb *= rgb;
        return vec4((clamp(rgb, 0.0, 1.0) + excess) + negative, srcPixel.a);
    }
    """

    static let shadow = """
    kernel vec4 chartShadow(__sample srcPixel, __sample adjustment, float strength) {
        vec3 negative = min(srcPixel.rgb, 0.0);
        vec3 excess = max(srcPixel.rgb, 1.0) - 1.0;
        vec3 rgb = clamp(srcPixel.rgb, 0.0, 1.0);
        float luma = sqrt(dot(rgb, vec3(0.3333300)));
        float t = mix(0.0, (3.400 * adjustment.r) - 1.200, strength);
        vec3 gain = t > 0.0 ? vec3(0.0 * t)
            : vec3(((-2.750) * t) * t, ((-2.750) * t) * t, ((-2.500) * t) * t);
        rgb = ((rgb * rgb) * gain) + (rgb * (1.0 - gain));
        float boost = 1.0 + ((1.850 * t) * max(0.1 - luma, 0.0));
        rgb = sqrt(clamp(boost * rgb, 0.0, 1.0));
        float middle = t < 0.0 ? min(t * t, 1.0) : 0.0;
        luma = luma * (1.0 - luma);
        float pivot = 0.4;
        float a = middle * luma;
        float b = (-pivot) * a;
        vec3 target = ((((rgb.r * vec3(0.299 * a)) + (rgb.g * vec3(0.587 * a)))
            + (rgb.b * vec3(0.114 * a))) + rgb) + vec3(b);
        rgb = mix(rgb, vec3(pivot), (-luma) * middle);
        rgb = max(mix(rgb, target, 0.8), 0.0);
        rgb *= rgb;
        return vec4((clamp(rgb, 0.0, 1.0) + excess) + negative, srcPixel.a);
    }
    """
    // Used only when the complete residual tap sequence needs more than the
    // two or three pairs already represented by the original public kernels.
    static func residual(pairs: Int) -> String {
        precondition((4...5).contains(pairs))
        let offsets = (0..<pairs).map { "vec2 o\($0)" }
        let weights = (0..<pairs).map { "float w\($0)" }
        var body = "kernel vec4 nativeResidual(sampler source, " + (offsets + weights).joined(separator: ", ") + ") {\nvec2 center = destCoord();\n"
        for index in (0..<pairs).reversed() {
            body += "vec4 n\(index) = sample(source, samplerTransform(source, center - o\(index)));\n"
        }
        for index in 0..<pairs {
            body += "vec4 p\(index) = sample(source, samplerTransform(source, center + o\(index)));\n"
        }
        var sum = "(w0 * (n0 + p0))"
        for index in 1..<pairs { sum = "(" + sum + " + (w\(index) * (n\(index) + p\(index))))" }
        return body + "return " + sum + ";\n}"
    }

}
