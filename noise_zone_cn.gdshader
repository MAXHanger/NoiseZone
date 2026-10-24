/* ============================================================
 * noise_zone_cn.gdshader —— 噪声遮罩特效
 * ------------------------------------------------------------
 * 整体效果：基于“黑白取值遮罩”的电视机风格特效——
 *   湍流马赛克 + 内外边缘发光 + 雪花噪点 + 画面扭曲折射 + 湍流溶解
 * ============================================================ */

shader_type canvas_item;

// ============================================================
// 1. 颜色
// ============================================================
group_uniforms pattern;
uniform vec4 block_color : source_color = vec4(0.5, 0.05, 0.05, 0.8);  // 遮罩内部基础底色
uniform vec4 glow_color : source_color = vec4(1.0, 0.2, 0.2, 1.0);     // 发光颜色（更明亮的亮红/亮橙）
uniform float glow_intensity : hint_range(1.0, 5.0) = 2.0;             // 发光强度倍率

// —— 边缘光晕控制（内外光晕共用这一组参数）——
uniform float glow_width : hint_range(0.0, 32.0, 1.0) = 8.0;   // 光晕宽度（像素，0 = 关闭光晕）
uniform float glow_falloff : hint_range(0.5, 8.0) = 2.0;       // 光晕衰减曲线（越大光晕收得越紧）
uniform float glow_opacity : hint_range(0.0, 1.0) = 0.5;       // 光晕整体不透明度

// 描边模式：0 = 原版（内外各 1 像素，共 2 像素），1 = 仅内边缘 1 像素，2 = 仅外边缘 1 像素
uniform int edge_mode : hint_range(0, 2) = 0;

// ============================================================
// 2. 湍流
// ============================================================
group_uniforms turbulence;
uniform sampler2D noise_tex : repeat_enable, filter_linear;    // 湍流噪声图

uniform float evolution_speed = 1.0;     // 湍流演化速度
uniform vec2 turbulence_scale = vec2(2.0, 2.0);                 // 噪声采样缩放
uniform float displacement_scale : hint_range(0.0, 1.2) = 0.04; // 边缘置换幅度

// ============================================================
// 3. 马赛克
// ============================================================
group_uniforms mosaic;
uniform float block_size : hint_range(1.0, 64.0, 1.0) = 8.0;    // 马赛克块大小（像素）

// ============================================================
// 4. 电视噪点
// ============================================================
group_uniforms tv;
uniform float noise_grain_strength : hint_range(0.0, 3.0) = 0.35; // 噪点强度 (0 为无噪点，1 为纯雪花)
uniform float noise_grain_speed : hint_range(1.0, 100.0) = 45.0;  // 噪点跳动刷新频率 (建议 30~60，模拟老电视刷新率)

// 噪声采样量化模式：0 = UV ，1 = block_uv
uniform int noise_mode : hint_range(0, 1) = 0;

// ============================================================
// 5. 叠加扭曲的游戏画面
// ============================================================
/* hint_screen_texture 声明一个 sampler2D screen_tex : hint_screen_texture;
   GPU 会自动抓取当前节点下方的游戏原画面供你随意采样 */
group_uniforms Refraction;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

// 扭曲折射烈度
uniform float screen_distortion_strength : hint_range(0.0, 5.0, 0.01) = 0.035;

// 顶层折射画面的整体不透明度 (0.0 = 纯原画，1.0 = 纯折射)
uniform float overlay_opacity : hint_range(0.0, 1.0) = 0.65;

// 湍流溶解控制
uniform float dissolve_threshold : hint_range(0.0, 1.0) = 0.45;  // 溶解阈值 (控制撕裂掏空的面积)
uniform float dissolve_contrast : hint_range(0.01, 5.5) = 0.15;  // 溶解对比度 (越小边缘越模糊)

// 顶层叠加模式：0 = 常规 ，alpha 混合 1 = 加法发光
uniform int blend_mode : hint_range(0, 1) = 0;

// ============================================================
// ---- 光照 ----
// ============================================================
group_uniforms light;
uniform float light_radius : hint_range(0.0, 2000.0) = 400.0;  // 有效半径（像素）
uniform float light_falloff : hint_range(0.5, 5.0) = 2.0;       // 衰减曲率
uniform float light_ambient : hint_range(0.0, 1.0) = 0.05;      // 环境底光

// ============================================================
// 辅助函数
// ============================================================

// 获得噪声值
vec2 get_combined_noise(vec2 uv, float time) {
	// 1. 双层交错流场（原地沸腾随机感）
	vec2 flow_1 = vec2(time * evolution_speed * 0.4, time * evolution_speed * 0.7);
	vec2 flow_2 = vec2(-time * evolution_speed * 0.5, -time * evolution_speed * 0.8);

	vec2 noise_1 = texture(noise_tex, uv * turbulence_scale + flow_1).rg;
	vec2 noise_2 = texture(noise_tex, uv * (turbulence_scale * 1.3) + flow_2).rg;
	vec2 c_noise = (noise_1 + noise_2) * 0.5;

	// 2. 返回融合 vec2 噪声
	return c_noise;
}

/* [核心辅助函数：将 TEXTURE 显式作为 sampler2D 参数传入] */
float get_turbulent_mask(sampler2D tex, vec2 uv, vec2 block_count, float time) {
	// 1. 马赛克量化
	vec2 b_uv = (floor(uv * block_count) + 0.5) / block_count;

	// 2. 获得噪声值随机值 [0.0~1.0]
	// 优化：原来对同一个 b_uv 连续采样了两次（浪费一倍纹理读取），合并为一次
	vec2 c_noise = get_combined_noise(b_uv, time);
	float a = c_noise.x * radians(360.); // 角度
	float r = c_noise.y * 2.0 - 1.0;     // 幅度
	
	// 3. 得到置换后的 UV
	vec2 displacement = vec2(cos(a), sin(a)) * r * displacement_scale;
	vec2 turbulent_uv = b_uv + displacement;

	// 4. 采样传入的纹理并硬二值化
	float m = texture(tex, turbulent_uv).r;
	return step(0.5, m);
}

/* [核心辅助函数：经典 GPU 随机雪花噪点哈希] */
float random_tv_noise(vec2 co, float time) {
	// 利用大质数乘积引发浮点数高频溢出截断，产生纯白噪声
	return fract(sin(dot(co, vec2(12.9898, 78.233)) + time) * 43758.5453123);
}

/*[核心辅助函数：对 num 进行 smoothstep 处理 */
float apply_smoothstep(float num, float threshold, float smoothness) {
    float lo = threshold - smoothness;
    float hi = threshold + smoothness;
    return smoothstep(lo, hi, num);
}

void fragment() {
	// 计算网格分块基准
	vec2 tex_size = 1.0 / TEXTURE_PIXEL_SIZE; // 纹理像素尺寸（如 1920x1080）
	vec2 block_count = tex_size / block_size; // 整个画面被切成多少个马赛克块
	vec2 step_uv = TEXTURE_PIXEL_SIZE;        // 边界线步长（1 像素）
	vec2 block_uv = (floor(UV * block_count) + 0.5) / block_count;
	/* [第 1 步：采样中心点，显式传入 TEXTURE 和 TIME] */
	float center = get_turbulent_mask(TEXTURE, UV, block_count, TIME);

	/* [第 2 步：十字采样上下左右 4 个邻居格子] */
	float up    = get_turbulent_mask(TEXTURE, UV + vec2(0.0, -step_uv.y), block_count, TIME);
	float down  = get_turbulent_mask(TEXTURE, UV + vec2(0.0, step_uv.y), block_count, TIME);
	float left  = get_turbulent_mask(TEXTURE, UV + vec2(-step_uv.x, 0.0), block_count, TIME);
	float right = get_turbulent_mask(TEXTURE, UV + vec2(step_uv.x, 0.0), block_count, TIME);

	// 计算 4 个邻居的遮罩总和 (范围 0.0 ~ 4.0)
	float neighbor_sum = up + down + left + right;

	/* [第 3 步：边缘判定] */
	// 内边缘：自己在内部 (center == 1.0)，但邻居没满 4 个 (说明紧贴着外界)
	bool is_inner_edge = (center > 0.5) && (neighbor_sum < 3.9);

	// 外边缘（光晕）：自己在外部 (center == 0.0)，但邻居有在内部的 (说明紧贴着内圈)
	bool is_outer_edge = (center < 0.5) && (neighbor_sum > 0.1);

	/* [第 4 步：计算柔和外光晕（Halo Glow）]
	 * 原理：对“遮罩外侧、且不属于原版 1 像素亮边”的像素，
	 *       沿 8 个方向向外逐像素探测离内侧边缘的最近距离 d，
	 *       光晕亮度按 (1 - d / glow_width)^glow_falloff 平滑衰减。
	 * 注意：fragment() 处理器内不允许使用 return，
	 *       因此光晕像素先在此输出颜色，再用下方 halo <= 0.001
	 *       判定跳过原版流程（原代码本体一行未动，仅外围包裹）。 */

	// 如果是外部像素，则检测它是否可以成为光晕像素
	float halo = 0.0; // 当前像素的光晕强度（0 = 无光晕）
	if (center < 0.5 && !is_outer_edge && glow_width > 0.01 && glow_opacity > 0.001) {
		// 快速预检：距边缘较远的像素只花 8 次探测即可排除，避免无效开销
		// 以光晕最远半径预检，保证光晕铺满设定宽度
		float probe_dist = max(1.0, glow_width);
		bool near_edge = false;
		// 从当前像素出发，向 8 个方向各探测一次，探测距离 = glow_width（光晕最远半径）
		for (int i = 0; i < 8; i++) {
			float ang = radians(float(i) * 360.0 / 8.0); // 角度转弧度
			vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE; // 方向向量
			// 说明至少一条射线碰到了内部，是靠近内部的像素，批准成为光晕像素
			if (get_turbulent_mask(TEXTURE, UV + dir * probe_dist, block_count, TIME) > 0.5) {
				// 任意一个方向在 glow_width 内碰到遮罩内部 → near_edge = true
				near_edge = true;
				break;
			}
			// 如果 8 个方向都碰不到 → 说明这个像素离边缘比光晕宽度还远 → 直接 halo = 0.0 → 在后面剔除
		}
		// 这个像素靠近边缘，有机会成为光晕像素
		if (near_edge) {
			// 从当前像素出发，向 8 个方向各探测一次
			for (int i = 0; i < 8; i++) {
				// 与预检角度错开半格，弥补 45° 采样间隔的探测盲区
				float ang = radians((float(i) + 0.5) * 360.0 / 8.0);
				vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE;
				// 每条射线从 d = 1 开始，一像素一像素往外走，d <= 32 是硬上限
				for (int d = 1; d <= 32; d++) {
					if (float(d) > glow_width) {
						break; // 已超出光晕最大宽度，该方向停止探测
					}
					// 一旦碰到遮罩内部（> 0.5）→ 说明这个方向离边缘有多远，记录下来
					if (get_turbulent_mask(TEXTURE, UV + dir * float(d), block_count, TIME) > 0.5) {
						// 按距离算亮度：
						// t = 0（d 很小，紧贴边缘）→ 亮度 1
						// t = 1（d 接近 glow_width）→ 亮度 0
						float t = clamp(float(d) / glow_width, 0.0, 1.0);
						// 离内部距离越小越亮，取最近的（最大的 halo 值）才是“离边缘最近距离”的正确表达
						halo = max(halo, pow(1.0 - t, glow_falloff)); // glow_falloff 越大，衰减越快
						break;
					}
				}
			}
			// 有光晕，是光晕像素
			if (halo > 0.001) {
				// 光晕像素：复用 glow_color 输出柔光（跳过原版流程由下方判定完成）
				COLOR.rgb = glow_color.rgb * glow_intensity * glow_opacity * halo;
				COLOR.a = glow_color.a * glow_opacity * halo;
			}
		}
	}

	// 非光晕像素 → 执行主逻辑（含 discard 与着色）；光晕像素已着色，直接跳过
	if (halo <= 0.001) {
		/* [第 5 步：剔除] */
		// 如果既不在内部，也不属于外边缘光晕，彻底丢弃
		// edge_mode == 1（仅内边缘）时，外侧 1 像素亮边也一并丢弃
		if (center < 0.5 && (!is_outer_edge || edge_mode == 1)) {
			discard;
		}

		/* [第 6 步：计算电视机雪花乱码噪点和高亮粒子] */
		/* 第 6-A 步 计算雪花乱码噪点 */
		float tv_time = floor(TIME * noise_grain_speed); // 量化时间，控制每秒闪烁帧率
		float grain = 0.; 
		
		// 得到 0.0 ~ 1.0 的黑白噪波
		if (noise_mode == 0) {
			// 模式 0：采样 UV
			grain = random_tv_noise(UV, tv_time);      
		} else {
			// 模式 1：采样block_uv
			grain = random_tv_noise(block_uv, tv_time);      
		}
		
		// 基础内部暗红底色
		vec3 base_rgb = block_color.rgb;

		// 混合电视噪声
		vec3 noisy_color = base_rgb + (vec3(grain) - 0.5) * noise_grain_strength;
	
		// 保护色彩不被加成死黑或过饱和
		noisy_color = clamp(noisy_color, vec3(0.0), vec3(1.0));

		
		/* [第 7 步：游戏画面扭曲采样] */

		/* [第 7-A 步：采样未经修改的绝对底层原画面 ] */
		vec4 clean_scene = textureLod(screen_tex, SCREEN_UV, 0.0);

		/* [第 7-B 步：采样被折射扭曲的顶层画面 ] */
		// 用 displacement 双向位移对 SCREEN_UV 实施扭曲拉扯
		vec2 screen_block_uv = (floor(SCREEN_UV * block_count) + 0.5) / block_count;
		// 优化：7-B 与 7-C 原本对同一个 (UV, TIME) 采样了两次，这里合并为一次共用
		vec2 combined_noise = get_combined_noise(UV, TIME);
		vec2 n = combined_noise;                        // -0.5~0.5 的扰动
		vec2 distorted_screen_uv = screen_block_uv + (n - 0.5) * screen_distortion_strength * 0.1;
		vec4 distorted_scene = textureLod(screen_tex, distorted_screen_uv, 0.0);

		/* [第 7-C 步：计算湍流动态溶解蒙版 ] */
		// 利用我们计算湍流时采样的噪声高度 (这里使用 combined_noise.r 作为高度场)
		// 使得溶解的斑驳形状和波浪的运动节奏 100% 吻合
		float noise_height = combined_noise.r;

		/* [第 7-D 步：给顶层扭曲画面染色并附加电视乱码] */
		// 让顶层的扭曲折射画面染上 基础底色 和 电视噪声
		vec3 tinted_distorted = mix(distorted_scene.rgb, noisy_color, 0.45);

		/* [第 7-E 步：双层合成] */
		// 使用 smoothstep 计算剥落镂空 Alpha：低于阈值的区域被溶解擦除
		float dissolve_mask = apply_smoothstep(noise_height,dissolve_threshold,dissolve_contrast);
		// 最终顶层的有效权重 = 湍流溶解蒙版 * 设定的图层透明度
		float final_overlay_weight = dissolve_mask * overlay_opacity;

		vec3 composite_result;
		if (blend_mode == 0) {
			// 模式 0：常规图层透明度混合 (保持原背景清晰，顶层斑驳折射膜半透叠加)
			composite_result = mix(clean_scene.rgb, tinted_distorted, final_overlay_weight);
		} else {
			// 模式 1：加法叠加 (类似能量屏障过曝发光，高光部分剧烈叠加)
			composite_result = clean_scene.rgb + tinted_distorted * final_overlay_weight;
		}

		/* [第 8 步：着色] */
		// 按 edge_mode 决定描边像素：0 = 内外 1px 双像素，1 = 仅内 1px，2 = 仅外 1px
		bool is_edge_pixel = (edge_mode == 0) ? (is_inner_edge || is_outer_edge) :
		                     (edge_mode == 1) ? is_inner_edge : is_outer_edge;
		if (is_edge_pixel) {
			// 【边缘处】：输出高亮发光色
			COLOR.rgb = glow_color.rgb * glow_intensity;
			COLOR.a = glow_color.a;
		} else {
			// 【纯内部】：输出带有噪点混合和游戏背景扭曲的基础暗红色
			COLOR.rgb = composite_result * 0.8;
			COLOR.a = block_color.a;
		}
	} // 光晕判定收尾：halo > 0 的光晕像素不会进入上面这段流程

	/* [第 9 步：内侧柔光（Inner Glow），与外光晕完全对称]
	 * 原理：对遮罩内侧像素，沿 8 个方向向外探测离边界外侧的
	 *       最近距离 d，越靠近边缘越亮；在原版第 8 步着色结果的
	 *       基础上，把颜色向 glow_color 柔和渐变混合（mix）。
	 *       参数与外光晕共用 glow_width / glow_falloff / glow_opacity。
	 *       基本相当于逻辑条件和外发光是反过来的 */
	if (center > 0.5 && glow_width > 0.01 && glow_opacity > 0.001) {
		// 快速预检：远离边界的内部像素只花 8 次探测即可排除，避免无效开销
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
			float inner_halo = 0.0; // 内侧光晕强度（0 = 无光晕）
			for (int i = 0; i < 8; i++) {
				// 与预检角度错开半格，弥补 45° 采样间隔的探测盲区
				float ang = radians((float(i) + 0.5) * 360.0 / 8.0);
				vec2 dir = vec2(cos(ang), sin(ang)) * TEXTURE_PIXEL_SIZE;
				for (int d = 1; d <= 32; d++) {
					if (float(d) > glow_width) {
						break; // 已超出光晕最大宽度，该方向停止探测
					}
					if (get_turbulent_mask(TEXTURE, UV + dir * float(d), block_count, TIME) < 0.5) {
						float t = clamp(float(d) / glow_width, 0.0, 1.0);
						inner_halo = max(inner_halo, pow(1.0 - t, glow_falloff)); // 距离越近越亮
						break;
					}
				}
			}
			if (inner_halo > 0.001) {
				// 内侧柔光：向发光色渐变混合（1 像素亮边处原版已输出全亮发光色，渐变无缝衔接）
				COLOR.rgb = mix(COLOR.rgb, glow_color.rgb * glow_intensity, glow_opacity * inner_halo);
			}
		}
	}
}

void light() {
	// 从光源指向当前像素的向量（屏幕空间）
	vec2 to_pixel = LIGHT_VERTEX.xy - LIGHT_POSITION.xy;
	float dist = length(to_pixel);

	// 归一化距离（0 = 光源中心，1 = 光照边界）
	float t = clamp(dist / light_radius, 0.0, 1.0);

	// 平滑衰减：(1 - t)^falloff，从中心 1 平滑到边缘 0
	float atten = pow(1.0 - t, light_falloff);

	// 输出
	LIGHT = LIGHT_COLOR * LIGHT_ENERGY * (atten + light_ambient);
}
