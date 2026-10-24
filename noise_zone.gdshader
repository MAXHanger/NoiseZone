/* ============================================================
 * noise_zone.gdshader — Noise-Mask Effect 
 * ------------------------------------------------------------
 * Overview: a CRT-style effect driven by a black-and-white mask —
 *   turbulent mosaic + inner/outer edge glow + TV grain +
 *   screen refraction + turbulent dissolve
 * ============================================================ */

shader_type canvas_item;

// ============================================================
// 1. Color 
// ============================================================
group_uniforms pattern;
uniform vec4 block_color : source_color = vec4(0.5, 0.05, 0.05, 0.8);  // Base color of the masked interior
uniform vec4 glow_color : source_color = vec4(1.0, 0.2, 0.2, 1.0);     // Glow color (brighter red/orange)
uniform float glow_intensity : hint_range(1.0, 5.0) = 2.0;             // Glow intensity multiplier

// —— Edge glow control (shared by the inner and outer glow) ——
uniform float glow_width : hint_range(0.0, 32.0, 1.0) = 8.0;   // Glow width in pixels (0 disables the glow)
uniform float glow_falloff : hint_range(0.5, 8.0) = 2.0;       // Glow falloff curve (larger = tighter falloff)
uniform float glow_opacity : hint_range(0.0, 1.0) = 0.5;       // Overall glow opacity

// Edge outline mode: 0 = original (1 px inner + 1 px outer), 1 = inner edge only, 2 = outer edge only
uniform int edge_mode : hint_range(0, 2) = 0;

// ============================================================
// 2. Turbulence 
// ============================================================
group_uniforms turbulence;
uniform sampler2D noise_tex : repeat_enable, filter_linear;    // Turbulence noise texture

uniform float evolution_speed = 1.0;     // Turbulence evolution speed
uniform vec2 turbulence_scale = vec2(2.0, 2.0);                 // Noise sampling scale
uniform float displacement_scale : hint_range(0.0, 1.2) = 0.04; // Edge displacement magnitude

// ============================================================
// 3. Mosaic 
// ============================================================
group_uniforms mosaic;
uniform float block_size : hint_range(1.0, 64.0, 1.0) = 8.0;    // Mosaic block size in pixels

// ============================================================
// 4. TV Grain
// ============================================================
group_uniforms tv;
uniform float noise_grain_strength : hint_range(0.0, 3.0) = 0.35; // Grain strength (0 = none, 1 = full static)
uniform float noise_grain_speed : hint_range(1.0, 100.0) = 45.0;  // Grain refresh rate in Hz (30–60 recommended, CRT-like)

// Grain sampling mode: 0 = raw UV, 1 = block-quantized UV (block_uv)
uniform int noise_mode : hint_range(0, 1) = 0;

// ============================================================
// 5. Screen Refraction of the Game View
// ============================================================
/* hint_screen_texture declares sampler2D screen_tex : hint_screen_texture;
   the GPU automatically captures the scene rendered beneath this node. */
group_uniforms Refraction;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

// Refraction strength
uniform float screen_distortion_strength : hint_range(0.0, 5.0, 0.01) = 0.035;

// Overall opacity of the refracted top layer (0 = raw scene, 1 = full refraction)
uniform float overlay_opacity : hint_range(0.0, 1.0) = 0.65;

// Turbulent dissolve
uniform float dissolve_threshold : hint_range(0.0, 1.0) = 0.45;  // Dissolve threshold (controls how much area is eaten away)
uniform float dissolve_contrast : hint_range(0.01, 5.5) = 0.15;  // Dissolve contrast (smaller = softer edges)

// Top-layer blend mode: 0 = normal alpha blending, 1 = additive (glow) blending
uniform int blend_mode : hint_range(0, 1) = 0;

// ============================================================
// ---- Light ----
// ============================================================
group_uniforms light;
uniform float light_radius : hint_range(0.0, 2000.0) = 400.0;  // Effective radius in pixels
uniform float light_falloff : hint_range(0.5, 5.0) = 2.0;       // Falloff exponent
uniform float light_ambient : hint_range(0.0, 1.0) = 0.05;      // Ambient floor

// ============================================================
// Helper Functions
// ============================================================

// Fetch the combined turbulence noise value
vec2 get_combined_noise(vec2 uv, float time) {
	// 1. Two interleaved flow fields (boiling-in-place look)
	vec2 flow_1 = vec2(time * evolution_speed * 0.4, time * evolution_speed * 0.7);
	vec2 flow_2 = vec2(-time * evolution_speed * 0.5, -time * evolution_speed * 0.8);

	vec2 noise_1 = texture(noise_tex, uv * turbulence_scale + flow_1).rg;
	vec2 noise_2 = texture(noise_tex, uv * (turbulence_scale * 1.3) + flow_2).rg;
	vec2 c_noise = (noise_1 + noise_2) * 0.5;

	// 2. Return the blended vec2 noise
	return c_noise;
}

/* [Core helper: takes TEXTURE explicitly as a sampler2D argument] */
float get_turbulent_mask(sampler2D tex, vec2 uv, vec2 block_count, float time) {
	// 1. Mosaic (block) quantization
	vec2 b_uv = (floor(uv * block_count) + 0.5) / block_count;

	// 2. Sample the noise once to derive the displacement angle and magnitude
	// (optimization: the same b_uv used to be sampled twice, doubling texture fetches)
	vec2 c_noise = get_combined_noise(b_uv, time);
	float a = c_noise.x * radians(360.); // Displacement angle
	float r = c_noise.y * 2.0 - 1.0;     // Displacement magnitude (signed)

	// 3. Compute the displaced UV
	vec2 displacement = vec2(cos(a), sin(a)) * r * displacement_scale;
	vec2 turbulent_uv = b_uv + displacement;

	// 4. Sample the input texture and binarize with a hard threshold
	float m = texture(tex, turbulent_uv).r;
	return step(0.5, m);
}

/* [Core helper: classic GPU hash for random snow/grain] */
float random_tv_noise(vec2 co, float time) {
	// Large-prime products cause high-frequency overflow truncation, producing white noise
	return fract(sin(dot(co, vec2(12.9898, 78.233)) + time) * 43758.5453123);
}

/* [Core helper: smoothstep with an adjustable half-width around a threshold] */
float apply_smoothstep(float num, float threshold, float smoothness) {
	float lo = threshold - smoothness;
	float hi = threshold + smoothness;
	return smoothstep(lo, hi, num);
}

void fragment() {
	// Grid/block reference values
	vec2 tex_size = 1.0 / TEXTURE_PIXEL_SIZE; // Texture size in pixels (e.g. 1920x1080)
	vec2 block_count = tex_size / block_size; // Number of mosaic blocks across the texture
	vec2 step_uv = TEXTURE_PIXEL_SIZE;        // Edge-detection step (1 pixel)
	vec2 block_uv = (floor(UV * block_count) + 0.5) / block_count;
	/* [Step 1: sample the center point, passing TEXTURE and TIME explicitly] */
	float center = get_turbulent_mask(TEXTURE, UV, block_count, TIME);

	/* [Step 2: cross-sample the 4 neighboring cells (up/down/left/right)] */
	float up    = get_turbulent_mask(TEXTURE, UV + vec2(0.0, -step_uv.y), block_count, TIME);
	float down  = get_turbulent_mask(TEXTURE, UV + vec2(0.0, step_uv.y), block_count, TIME);
	float left  = get_turbulent_mask(TEXTURE, UV + vec2(-step_uv.x, 0.0), block_count, TIME);
	float right = get_turbulent_mask(TEXTURE, UV + vec2(step_uv.x, 0.0), block_count, TIME);

	// Sum of the 4 neighbors (range 0.0 ~ 4.0)
	float neighbor_sum = up + down + left + right;

	/* [Step 3: edge classification] */
	// Inner edge: the pixel is inside (center == 1.0), but its neighbors are not all
	// inside (meaning it directly borders the outside)
	bool is_inner_edge = (center > 0.5) && (neighbor_sum < 3.9);

	// Outer edge: the pixel is outside (center == 0.0) but has inside neighbors
	// (meaning it directly borders the interior)
	bool is_outer_edge = (center < 0.5) && (neighbor_sum > 0.1);

	/* [Step 4: compute the soft outer glow (halo)]
	 * Principle: for pixels outside the mask (excluding the 1-px outline),
	 *   probe outward along 8 directions, pixel by pixel, for the nearest
	 *   distance d to the interior; the glow brightness follows
	 *   (1 - d / glow_width)^glow_falloff.
	 * Note: the fragment() processor forbids `return`, so halo pixels write
	 *   their color here, and the halo <= 0.001 branch below skips the
	 *   original pipeline (the original code itself is untouched). */

	// For outside pixels, test whether they qualify as halo pixels
	float halo = 0.0; // Halo strength of the current pixel (0 = none)
	if (center < 0.5 && !is_outer_edge && glow_width > 0.01 && glow_opacity > 0.001) {
		// Quick pre-check: pixels far from the edge are rejected after just 8 probes,
		// avoiding wasted work
		// Probe at the farthest halo radius so the halo spans the configured width
		float probe_dist = max(1.0, glow_width);
		bool near_edge = false;
		// From the current pixel, probe 8 directions once each, at distance = glow_width
		for (int i = 0; i < 8; i++) {
			float ang = radians(float(i) * 360.0 / 8.0); // Degrees to radians
			vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE; // Direction vector
			// If at least one ray reaches the interior, this pixel is close to the boundary
			if (get_turbulent_mask(TEXTURE, UV + dir * probe_dist, block_count, TIME) > 0.5) {
				// Any direction reaching the interior within glow_width → near_edge = true
				near_edge = true;
				break;
			}
			// If all 8 directions miss → the pixel is farther than glow_width from the edge
			// → halo stays 0.0 and the pixel is discarded later
		}
		// This pixel is near the edge, so it can become a halo pixel
		if (near_edge) {
			// Probe outward along 8 directions again
			for (int i = 0; i < 8; i++) {
				// Offset the angle by half a step to cover the blind spots between 45° samples
				float ang = radians((float(i) + 0.5) * 360.0 / 8.0);
				vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE;
				// Each ray walks outward 1 pixel at a time; d <= 32 is a hard cap
				for (int d = 1; d <= 32; d++) {
					if (float(d) > glow_width) {
						break; // Past the maximum halo width; stop probing this direction
					}
					// On the first hit of the interior (> 0.5), record the distance
					if (get_turbulent_mask(TEXTURE, UV + dir * float(d), block_count, TIME) > 0.5) {
						// Brightness from distance:
						// t = 0 (small d, right at the edge) → brightness 1
						// t = 1 (d near glow_width) → brightness 0
						float t = clamp(float(d) / glow_width, 0.0, 1.0);
						// Closer to the interior = brighter; keeping the largest value
						// yields the correct "distance to the nearest edge"
						halo = max(halo, pow(1.0 - t, glow_falloff)); // Larger glow_falloff = faster decay
						break;
					}
				}
			}
			// Halo present → this is a halo pixel
			if (halo > 0.001) {
				// Halo pixel: output soft light using glow_color
				// (skipping the original pipeline is handled by the branch below)
				COLOR.rgb = glow_color.rgb * glow_intensity * glow_opacity * halo;
				COLOR.a = glow_color.a * glow_opacity * halo;
			}
		}
	}

	// Non-halo pixels → run the main pipeline (discard + shading);
	// halo pixels are already shaded and skip it
	if (halo <= 0.001) {
		/* [Step 5: culling] */
		// Discard pixels that are neither inside nor part of the outer-edge glow
		// With edge_mode == 1 (inner edge only), the outer 1-px outline is discarded too
		if (center < 0.5 && (!is_outer_edge || edge_mode == 1)) {
			discard;
		}

		/* [Step 6: TV grain/static] */
		/* Step 6-A: compute the snow grain */
		float tv_time = floor(TIME * noise_grain_speed); // Quantized time controls the flicker rate
		float grain = 0.;

		// Black-and-white noise in the 0.0 ~ 1.0 range
		if (noise_mode == 0) {
			// Mode 0: sample raw UV
			grain = random_tv_noise(UV, tv_time);
		} else {
			// Mode 1: sample block_uv
			grain = random_tv_noise(block_uv, tv_time);
		}

		// Dark-red base color of the interior
		vec3 base_rgb = block_color.rgb;

		// Blend in the TV grain
		vec3 noisy_color = base_rgb + (vec3(grain) - 0.5) * noise_grain_strength;

		// Clamp to avoid pure black or oversaturation
		noisy_color = clamp(noisy_color, vec3(0.0), vec3(1.0));

		/* [Step 7: refraction sampling of the game view] */

		/* [Step 7-A: sample the untouched base scene ] */
		vec4 clean_scene = textureLod(screen_tex, SCREEN_UV, 0.0);

		/* [Step 7-B: sample the refracted top view ] */
		// Displace SCREEN_UV in both directions to warp the scene
		vec2 screen_block_uv = (floor(SCREEN_UV * block_count) + 0.5) / block_count;
		// Optimization: 7-B and 7-C previously sampled the same (UV, TIME) twice; shared here
		vec2 combined_noise = get_combined_noise(UV, TIME);
		vec2 n = combined_noise;                        // Perturbation in the -0.5 ~ 0.5 range
		vec2 distorted_screen_uv = screen_block_uv + (n - 0.5) * screen_distortion_strength * 0.1;
		vec4 distorted_scene = textureLod(screen_tex, distorted_screen_uv, 0.0);

		/* [Step 7-C: compute the turbulent dissolve mask] */
		// Reuse the noise height sampled for the turbulence (combined_noise.r as the height field)
		// so the dissolve pattern matches the wave motion 100%
		float noise_height = combined_noise.r;

		/* [Step 7-D: tint the distorted top view with grain] */
		// Tint the refracted top view with the dark-red base color and the TV grain
		vec3 tinted_distorted = mix(distorted_scene.rgb, noisy_color, 0.45);

		/* [Step 7-E: two-layer compositing] */
		// smoothstep produces the dissolved alpha: areas below the threshold are eaten away
		float dissolve_mask = apply_smoothstep(noise_height, dissolve_threshold, dissolve_contrast);
		// Final top-layer weight = dissolve mask * configured layer opacity
		float final_overlay_weight = dissolve_mask * overlay_opacity;

		vec3 composite_result;
		if (blend_mode == 0) {
			// Mode 0: regular alpha blending (keeps the background crisp, top layer semi-transparent)
			composite_result = mix(clean_scene.rgb, tinted_distorted, final_overlay_weight);
		} else {
			// Mode 1: additive blending (energy-barrier overexposure; highlights add up hard)
			composite_result = clean_scene.rgb + tinted_distorted * final_overlay_weight;
		}

		/* [Step 8: shading] */
		// Edge pixels selected by edge_mode: 0 = inner + outer 1 px, 1 = inner only, 2 = outer only
		bool is_edge_pixel = (edge_mode == 0) ? (is_inner_edge || is_outer_edge) :
		                     (edge_mode == 1) ? is_inner_edge : is_outer_edge;
		if (is_edge_pixel) {
			// [At the edge]: output the bright glow color
			COLOR.rgb = glow_color.rgb * glow_intensity;
			COLOR.a = glow_color.a;
		} else {
			// [Pure interior]: dark-red base with grain and the refracted game view
			COLOR.rgb = composite_result * 0.8;
			COLOR.a = block_color.a;
		}
	} // End of the halo branch: pixels with halo > 0 skip the block above

	/* [Step 9: inner glow, fully symmetric with the outer glow]
	 * Principle: for pixels inside the mask, probe outward along 8 directions
	 *   for the nearest distance d to the outside; the closer to the edge,
	 *   the brighter. Blends the Step-8 result toward glow_color with a soft mix.
	 *   Shares glow_width / glow_falloff / glow_opacity with the outer glow.
	 *   Effectively the outer glow with its conditions inverted */
	if (center > 0.5 && glow_width > 0.01 && glow_opacity > 0.001) {
		// Quick pre-check: interior pixels far from the edge are rejected after just 8 probes
		float probe_dist = max(1.0, glow_width);
		bool near_edge = false;
		for (int i = 0; i < 8; i++) {
			float ang = radians(float(i) * 360.0 / 8.0);
			vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE;
			if (get_turbulent_mask(TEXTURE, UV + dir * probe_dist, block_count, TIME) < 0.5) {
				near_edge = true;
				break;
			}
		}
		if (near_edge) {
			float inner_halo = 0.0; // Inner glow strength (0 = none)
			for (int i = 0; i < 8; i++) {
				// Offset the angle by half a step to cover the blind spots between 45° samples
				float ang = radians((float(i) + 0.5) * 360.0 / 8.0);
				vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE;
				for (int d = 1; d <= 32; d++) {
					if (float(d) > glow_width) {
						break; // Past the maximum glow width; stop probing this direction
					}
					if (get_turbulent_mask(TEXTURE, UV + dir * float(d), block_count, TIME) < 0.5) {
						float t = clamp(float(d) / glow_width, 0.0, 1.0);
						inner_halo = max(inner_halo, pow(1.0 - t, glow_falloff)); // Closer to the edge = brighter
						break;
					}
				}
			}
			if (inner_halo > 0.001) {
				// Inner glow: soft blend toward the glow color
				// (at the 1-px edge the original pipeline already outputs the full glow color,
				// so the gradient joins seamlessly)
				COLOR.rgb = mix(COLOR.rgb, glow_color.rgb * glow_intensity, glow_opacity * inner_halo);
			}
		}
	}
}

void light() {
	// Vector from the light source to the current pixel (screen space)
	vec2 to_pixel = LIGHT_VERTEX.xy - LIGHT_POSITION.xy;
	float dist = length(to_pixel);

	// Normalized distance (0 = light center, 1 = light boundary)
	float t = clamp(dist / light_radius, 0.0, 1.0);

	// Smooth attenuation: (1 - t)^falloff, 1 at the center down to 0 at the edge
	float atten = pow(1.0 - t, light_falloff);

	// Output
	LIGHT = LIGHT_COLOR * LIGHT_ENERGY * (atten + light_ambient);
}
