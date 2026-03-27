module Slug
  module Binary
    def self.uint8(data, offset)
      data.getbyte(offset)
    end

    def self.int8(data, offset)
      v = data.getbyte(offset)
      v >= 0x80 ? v - 0x100 : v
    end

    def self.uint16(data, offset)
      (data.getbyte(offset) << 8) | data.getbyte(offset + 1)
    end

    def self.int16(data, offset)
      v = (data.getbyte(offset) << 8) | data.getbyte(offset + 1)
      v >= 0x8000 ? v - 0x10000 : v
    end

    def self.uint32(data, offset)
      (data.getbyte(offset) << 24) | (data.getbyte(offset + 1) << 16) |
        (data.getbyte(offset + 2) << 8) | data.getbyte(offset + 3)
    end

    def self.int32(data, offset)
      v = uint32(data, offset)
      v >= 0x80000000 ? v - 0x100000000 : v
    end

    def self.tag(data, offset)
      data.getbyte(offset).chr + data.getbyte(offset + 1).chr +
        data.getbyte(offset + 2).chr + data.getbyte(offset + 3).chr
    end
  end

  module TTF
    B = Slug::Binary

    class << self
      def parse_table_directory(data)
        num_tables = B.uint16(data, 4)
        tables = {}
        num_tables.times do |i|
          off = 12 + i * 16
          t = B.tag(data, off)
          tables[t] = { offset: B.uint32(data, off + 8), length: B.uint32(data, off + 12) }
        end
        tables
      end

      def parse_head(data, table)
        o = table[:offset]
        {
          units_per_em: B.uint16(data, o + 18),
          x_min: B.int16(data, o + 36),
          y_min: B.int16(data, o + 38),
          x_max: B.int16(data, o + 40),
          y_max: B.int16(data, o + 42),
          index_to_loc_format: B.int16(data, o + 50)
        }
      end

      def parse_maxp(data, table)
        { num_glyphs: B.uint16(data, table[:offset] + 4) }
      end

      def parse_hhea(data, table)
        o = table[:offset]
        {
          ascent: B.int16(data, o + 4),
          descent: B.int16(data, o + 6),
          line_gap: B.int16(data, o + 8),
          num_h_metrics: B.uint16(data, o + 34)
        }
      end

      def parse_os2(data, table)
        return nil unless table
        o = table[:offset]
        version = B.uint16(data, o)
        # sCapHeight is at offset 88, available in OS/2 version >= 2
        cap_height = version >= 2 ? B.int16(data, o + 88) : nil
        { version: version, cap_height: cap_height }
      end

      def parse_hmtx(data, table, num_h_metrics, num_glyphs)
        o = table[:offset]
        metrics = []
        last_aw = 0

        num_h_metrics.times do |i|
          aw = B.uint16(data, o)
          lsb = B.int16(data, o + 2)
          metrics << { advance_width: aw, lsb: lsb }
          last_aw = aw
          o += 4
        end

        (num_h_metrics...num_glyphs).each do |_|
          lsb = B.int16(data, o)
          metrics << { advance_width: last_aw, lsb: lsb }
          o += 2
        end

        metrics
      end

      def parse_loca(data, table, format, num_glyphs)
        o = table[:offset]
        offsets = []

        if format == 0
          (num_glyphs + 1).times do |i|
            offsets << B.uint16(data, o + i * 2) * 2
          end
        else
          (num_glyphs + 1).times do |i|
            offsets << B.uint32(data, o + i * 4)
          end
        end

        offsets
      end

      def parse_cmap(data, table)
        o = table[:offset]
        num_subtables = B.uint16(data, o + 2)

        subtable_offset = nil
        num_subtables.times do |i|
          rec = o + 4 + i * 8
          platform_id = B.uint16(data, rec)
          encoding_id = B.uint16(data, rec + 2)
          sub_off = B.uint32(data, rec + 4)

          if (platform_id == 3 && encoding_id == 1) || platform_id == 0
            subtable_offset = o + sub_off
            break if platform_id == 3
          end
        end

        return { lookup: ->(c) { 0 } } unless subtable_offset

        format = B.uint16(data, subtable_offset)
        return { lookup: ->(c) { 0 } } unless format == 4

        parse_cmap_format4(data, subtable_offset)
      end

      def parse_cmap_format4(data, o)
        seg_count = B.uint16(data, o + 6).idiv(2)

        end_codes = []
        start_codes = []
        id_deltas = []
        id_range_offsets = []

        end_off = o + 14
        start_off = end_off + seg_count * 2 + 2
        delta_off = start_off + seg_count * 2
        range_off = delta_off + seg_count * 2

        seg_count.times do |i|
          end_codes << B.uint16(data, end_off + i * 2)
          start_codes << B.uint16(data, start_off + i * 2)
          id_deltas << B.int16(data, delta_off + i * 2)
          id_range_offsets << B.uint16(data, range_off + i * 2)
        end

        cache = {}

        lookup = ->(charcode) {
          return cache[charcode] if cache.key?(charcode)

          glyph_id = 0
          seg_count.times do |i|
            next if charcode > end_codes[i]
            if charcode >= start_codes[i]
              if id_range_offsets[i] == 0
                glyph_id = (charcode + id_deltas[i]) & 0xFFFF
              else
                addr = range_off + i * 2 + id_range_offsets[i] + (charcode - start_codes[i]) * 2
                glyph_id = B.uint16(data, addr)
                glyph_id = (glyph_id + id_deltas[i]) & 0xFFFF if glyph_id != 0
              end
            end
            break
          end

          cache[charcode] = glyph_id
          glyph_id
        }

        { lookup: lookup }
      end

      ON_CURVE = 0x01
      X_SHORT_VECTOR = 0x02
      Y_SHORT_VECTOR = 0x04
      REPEAT_FLAG = 0x08
      X_SAME_OR_POS = 0x10
      Y_SAME_OR_POS = 0x20

      ARG_1_AND_2_ARE_WORDS = 0x0001
      ARGS_ARE_XY_VALUES = 0x0002
      WE_HAVE_A_SCALE = 0x0008
      MORE_COMPONENTS = 0x0020
      WE_HAVE_XY_SCALE = 0x0040
      WE_HAVE_TWO_BY_TWO = 0x0080

      def parse_glyph(data, glyf_offset, loca, glyph_id, cache, depth = 0)
        return nil if depth > 10
        return cache[glyph_id] if cache.key?(glyph_id)

        glyph_start = loca[glyph_id]
        glyph_end = loca[glyph_id + 1]
        return nil if glyph_start == glyph_end

        o = glyf_offset + glyph_start
        num_contours = B.int16(data, o)
        x_min = B.int16(data, o + 2)
        y_min = B.int16(data, o + 4)
        x_max = B.int16(data, o + 6)
        y_max = B.int16(data, o + 8)

        if num_contours >= 0
          glyph = parse_simple_glyph(data, o, num_contours, x_min, y_min, x_max, y_max)
        else
          glyph = parse_compound_glyph(data, o, glyf_offset, loca, cache, depth, x_min, y_min, x_max, y_max)
        end

        cache[glyph_id] = glyph
        glyph
      end

      def parse_simple_glyph(data, o, num_contours, x_min, y_min, x_max, y_max)
        return { curves: [], x_min: x_min, y_min: y_min, x_max: x_max, y_max: y_max } if num_contours == 0

        off = o + 10
        end_pts = []
        num_contours.times do |i|
          end_pts << B.uint16(data, off + i * 2)
        end
        off += num_contours * 2

        instruction_length = B.uint16(data, off)
        off += 2 + instruction_length

        num_points = end_pts.last + 1

        # Read flags
        flags = []
        while flags.length < num_points
          flag = B.uint8(data, off)
          off += 1
          flags << flag
          if (flag & REPEAT_FLAG) != 0
            repeat = B.uint8(data, off)
            off += 1
            repeat.times { flags << flag }
          end
        end

        # Read x coordinates
        x_coords = []
        x = 0
        num_points.times do |i|
          f = flags[i]
          if (f & X_SHORT_VECTOR) != 0
            dx = B.uint8(data, off)
            off += 1
            dx = -dx if (f & X_SAME_OR_POS) == 0
          elsif (f & X_SAME_OR_POS) != 0
            dx = 0
          else
            dx = B.int16(data, off)
            off += 2
          end
          x += dx
          x_coords << x
        end

        # Read y coordinates
        y_coords = []
        y = 0
        num_points.times do |i|
          f = flags[i]
          if (f & Y_SHORT_VECTOR) != 0
            dy = B.uint8(data, off)
            off += 1
            dy = -dy if (f & Y_SAME_OR_POS) == 0
          elsif (f & Y_SAME_OR_POS) != 0
            dy = 0
          else
            dy = B.int16(data, off)
            off += 2
          end
          y += dy
          y_coords << y
        end

        # Build points with the on-curve flag
        points = []
        num_points.times do |i|
          points << { x: x_coords[i].to_f, y: y_coords[i].to_f, on: (flags[i] & ON_CURVE) != 0 }
        end

        # Convert contours to quadratic Bezier curves
        curves = []
        contour_start = 0
        end_pts.each do |end_pt|
          contour = points[contour_start..end_pt]
          curves.concat(contour_to_beziers(contour)) if contour.length >= 2
          contour_start = end_pt + 1
        end

        tag_degenerate_curves(curves)
        { curves: curves, x_min: x_min, y_min: y_min, x_max: x_max, y_max: y_max }
      end

      EPS = 1.0 / 1024.0

      def tag_degenerate_curves(curves)
        curves.each do |c|
          c[:horiz] = (c[:p1][1] - c[:p2][1]).abs < EPS &&
                      (c[:p2][1] - c[:p3][1]).abs < EPS
          c[:vert] = (c[:p1][0] - c[:p2][0]).abs < EPS &&
                     (c[:p2][0] - c[:p3][0]).abs < EPS
        end
      end

      def contour_to_beziers(contour)
        n = contour.length
        return [] if n < 2

        # Build a point list where we know the on-curve status.
        # Insert implicit on-curve midpoints between consecutive off-curve points,
        # so the resulting list strictly alternates: on, off, on, off, on, ...
        expanded = []

        # Find a starting on-curve point
        start = nil
        n.times do |i|
          if contour[i][:on]
            start = i
            break
          end
        end

        # If no on-curve point exists, create one between the first and last off-curve
        if start.nil?
          mx = (contour[0][:x] + contour[n - 1][:x]) * 0.5
          my = (contour[0][:y] + contour[n - 1][:y]) * 0.5
          expanded << [mx, my, true]
          start = 0
        end

        # Walk all points starting from 'start', inserting midpoints as needed
        n.times do |i|
          idx = (start + i) % n
          pt = contour[idx]

          if !pt[:on] && expanded.length > 0 && !expanded.last[2]
            # Two consecutive off-curves: insert implicit on-curve midpoint
            prev = expanded.last
            mx = (prev[0] + pt[:x]) * 0.5
            my = (prev[1] + pt[:y]) * 0.5
            expanded << [mx, my, true]
          end

          expanded << [pt[:x], pt[:y], pt[:on]]
        end

        # If last and first are both off-curve, insert midpoint
        if !expanded.last[2] && !expanded.first[2]
          mx = (expanded.last[0] + expanded.first[0]) * 0.5
          my = (expanded.last[1] + expanded.first[1]) * 0.5
          expanded << [mx, my, true]
        end

        # Build curves
        # Find the first on-curve in expanded
        first_on = 0
        expanded.length.times do |i|
          if expanded[i][2]
            first_on = i
            break
          end
        end

        curves = []
        en = expanded.length
        cur = expanded[first_on]
        i = 1

        while i < en
          idx = (first_on + i) % en
          pt = expanded[idx]

          if pt[2]
            # on-curve to on-curve--line segment as degenerate Bezier
            mx = (cur[0] + pt[0]) * 0.5
            my = (cur[1] + pt[1]) * 0.5
            curves << { p1: [cur[0], cur[1]], p2: [mx, my], p3: [pt[0], pt[1]] }
            cur = pt
            i += 1
          else
            # off-curve--next must be on-curve
            idx2 = (first_on + i + 1) % en
            pt2 = expanded[idx2]
            curves << { p1: [cur[0], cur[1]], p2: [pt[0], pt[1]], p3: [pt2[0], pt2[1]] }
            cur = pt2
            i += 2
          end
        end

        # Close the contour if needed
        start_pt = expanded[first_on]
        if (cur[0] - start_pt[0]).abs > 0.01 || (cur[1] - start_pt[1]).abs > 0.01
          mx = (cur[0] + start_pt[0]) * 0.5
          my = (cur[1] + start_pt[1]) * 0.5
          curves << { p1: [cur[0], cur[1]], p2: [mx, my], p3: [start_pt[0], start_pt[1]] }
        end

        curves
      end

      def parse_compound_glyph(data, o, glyf_offset, loca, cache, depth, x_min, y_min, x_max, y_max)
        curves = []
        off = o + 10

        loop do
          flags = B.uint16(data, off)
          glyph_index = B.uint16(data, off + 2)
          off += 4

          if (flags & ARG_1_AND_2_ARE_WORDS) != 0
            if (flags & ARGS_ARE_XY_VALUES) != 0
              dx = B.int16(data, off)
              dy = B.int16(data, off + 2)
            else
              dx = 0
              dy = 0
            end
            off += 4
          else
            if (flags & ARGS_ARE_XY_VALUES) != 0
              dx = B.int8(data, off)
              dy = B.int8(data, off + 1)
            else
              dx = 0
              dy = 0
            end
            off += 2
          end

          scale_x = 1.0
          scale_y = 1.0
          scale_01 = 0.0
          scale_10 = 0.0

          if (flags & WE_HAVE_A_SCALE) != 0
            scale_x = B.int16(data, off) / 16384.0
            scale_y = scale_x
            off += 2
          elsif (flags & WE_HAVE_XY_SCALE) != 0
            scale_x = B.int16(data, off) / 16384.0
            scale_y = B.int16(data, off + 2) / 16384.0
            off += 4
          elsif (flags & WE_HAVE_TWO_BY_TWO) != 0
            scale_x = B.int16(data, off) / 16384.0
            scale_01 = B.int16(data, off + 2) / 16384.0
            scale_10 = B.int16(data, off + 4) / 16384.0
            scale_y = B.int16(data, off + 6) / 16384.0
            off += 8
          end

          component = parse_glyph(data, glyf_offset, loca, glyph_index, cache, depth + 1)
          if component && component[:curves]
            component[:curves].each do |c|
              transformed = {
                p1: transform_point(c[:p1], scale_x, scale_01, scale_10, scale_y, dx, dy),
                p2: transform_point(c[:p2], scale_x, scale_01, scale_10, scale_y, dx, dy),
                p3: transform_point(c[:p3], scale_x, scale_01, scale_10, scale_y, dx, dy)
              }
              curves << transformed
            end
          end

          break if (flags & MORE_COMPONENTS) == 0
        end

        tag_degenerate_curves(curves)
        { curves: curves, x_min: x_min, y_min: y_min, x_max: x_max, y_max: y_max }
      end

      def transform_point(pt, sx, s01, s10, sy, dx, dy)
        [pt[0] * sx + pt[1] * s10 + dx.to_f,
         pt[0] * s01 + pt[1] * sy + dy.to_f]
      end
    end
  end

  module Rasterizer
    def self.clamp(val, lo, hi)
      val < lo ? lo : (val > hi ? hi : val)
    end

    def self.calc_root_code(v1, v2, v3)
      i1 = v1 < 0.0 ? 1 : 0
      i2 = (v2 < 0.0 ? 1 : 0) << 1
      i3 = (v3 < 0.0 ? 1 : 0) << 2
      shift = i3 | i2 | i1
      (0x2E74 >> shift) & 0x0101
    end

    def self.solve_horiz_poly(p1x, p1y, p2x, p2y, p3x, p3y)
      ax = p1x - 2.0 * p2x + p3x
      ay = p1y - 2.0 * p2y + p3y
      bx = p1x - p2x
      by = p1y - p2y

      if ay.abs < (1.0 / 65536.0)
        rb = 0.5 / by
        t1 = p1y * rb
        t2 = t1
      else
        disc = by * by - ay * p1y
        disc = 0.0 if disc < 0.0
        d = Math.sqrt(disc)
        ra = 1.0 / ay
        t1 = (by - d) * ra
        t2 = (by + d) * ra
      end

      x1 = (ax * t1 - bx * 2.0) * t1 + p1x
      x2 = (ax * t2 - bx * 2.0) * t2 + p1x
      [x1, x2]
    end

    def self.solve_vert_poly(p1x, p1y, p2x, p2y, p3x, p3y)
      ax = p1x - 2.0 * p2x + p3x
      ay = p1y - 2.0 * p2y + p3y
      bx = p1x - p2x
      by = p1y - p2y

      if ax.abs < (1.0 / 65536.0)
        rb = 0.5 / bx
        t1 = p1x * rb
        t2 = t1
      else
        disc = bx * bx - ax * p1x
        disc = 0.0 if disc < 0.0
        d = Math.sqrt(disc)
        ra = 1.0 / ax
        t1 = (bx - d) * ra
        t2 = (bx + d) * ra
      end

      y1 = (ay * t1 - by * 2.0) * t1 + p1y
      y2 = (ay * t2 - by * 2.0) * t2 + p1y
      [y1, y2]
    end

    def self.calc_coverage(xcov, ycov, xwgt, ywgt)
      denom = xwgt + ywgt
      denom = 1.0 / 65536.0 if denom < 1.0 / 65536.0

      coverage = [((xcov * xwgt + ycov * ywgt).abs / denom),
                  [xcov.abs, ycov.abs].min].max

      clamp(coverage, 0.0, 1.0)
    end

    # Build spatial band index for a glyph's curves
    def self.build_bands(curves, y_min, y_max, x_min, x_max)
      nc = curves.length
      return nil if nc < 4  # not worth banding for tiny curve counts

      eps = (y_max - y_min) / 1024.0

      # Number of bands: sqrt(curves), clamped to [2, 32]
      num_h = clamp(Math.sqrt(nc).ceil, 2, 32)
      num_v = clamp(Math.sqrt(nc).ceil, 2, 32)

      h_thickness = (y_max - y_min).to_f / num_h
      v_thickness = (x_max - x_min).to_f / num_v

      return nil if h_thickness <= 0 || v_thickness <= 0

      # Precompute curve bounding boxes
      curve_bounds = curves.map do |c|
        xs = [c[:p1][0], c[:p2][0], c[:p3][0]]
        ys = [c[:p1][1], c[:p2][1], c[:p3][1]]
        { min_x: xs.min, max_x: xs.max, min_y: ys.min, max_y: ys.max }
      end

      # Build horizontal bands (for horizontal ray testing — skip horiz lines)
      h_bands = Array.new(num_h) { [] }
      curves.each_with_index do |c, i|
        next if c[:horiz]
        b = curve_bounds[i]
        # Which bands does this curve's y range overlap?
        b_lo = clamp(((b[:min_y] - eps - y_min) / h_thickness).floor, 0, num_h - 1)
        b_hi = clamp(((b[:max_y] + eps - y_min) / h_thickness).floor, 0, num_h - 1)
        (b_lo..b_hi).each { |bi| h_bands[bi] << i }
      end

      # Sort each horizontal band by descending max_x (for early exit)
      h_bands.each do |band|
        band.replace(band.sort_by { |i| -curve_bounds[i][:max_x] })
      end

      # Build vertical bands (for vertical ray testing — skip vert lines)
      v_bands = Array.new(num_v) { [] }
      curves.each_with_index do |c, i|
        next if c[:vert]
        b = curve_bounds[i]
        b_lo = clamp(((b[:min_x] - eps - x_min) / v_thickness).floor, 0, num_v - 1)
        b_hi = clamp(((b[:max_x] + eps - x_min) / v_thickness).floor, 0, num_v - 1)
        (b_lo..b_hi).each { |bi| v_bands[bi] << i }
      end

      # Sort each vertical band by descending max_y (for early exit)
      v_bands.each do |band|
        band.replace(band.sort_by { |i| -curve_bounds[i][:max_y] })
      end

      {
        h_bands: h_bands, v_bands: v_bands,
        curve_bounds: curve_bounds,
        num_h: num_h, num_v: num_v,
        h_thickness: h_thickness, v_thickness: v_thickness,
        y_min: y_min.to_f, x_min: x_min.to_f
      }
    end

    def self.rasterize_glyph(curves, width, height, ppfu, origin_x, origin_y, stem_darkening = false)
      pixels = Array.new(width * height, 0)
      fupp = 1.0 / ppfu

      # Build band index for this glyph
      glyph_y_min = origin_y
      glyph_y_max = origin_y + height * fupp
      glyph_x_min = origin_x
      glyph_x_max = origin_x + width * fupp
      bands = build_bands(curves, glyph_y_min, glyph_y_max, glyph_x_min, glyph_x_max)

      height.times do |row|
        sy = origin_y + (row + 0.5) * fupp

        # Determine horizontal band for this row
        if bands
          h_bi = clamp(((sy - bands[:y_min]) / bands[:h_thickness]).floor, 0, bands[:num_h] - 1)
          h_curve_indices = bands[:h_bands][h_bi]
        end

        width.times do |col|
          sx = origin_x + (col + 0.5) * fupp

          xcov = 0.0
          xwgt = 0.0
          ycov = 0.0
          ywgt = 0.0

          if bands
            # Banded: horizontal ray
            h_curve_indices.each do |ci|
              c = curves[ci]
              b = bands[:curve_bounds][ci]

              # Early exit: curves sorted by descending max_x
              break if (b[:max_x] - sx) * ppfu < -0.5

              rp1x = c[:p1][0] - sx; rp1y = c[:p1][1] - sy
              rp2x = c[:p2][0] - sx; rp2y = c[:p2][1] - sy
              rp3x = c[:p3][0] - sx; rp3y = c[:p3][1] - sy

              hcode = calc_root_code(rp1y, rp2y, rp3y)
              if hcode != 0
                rx = solve_horiz_poly(rp1x, rp1y, rp2x, rp2y, rp3x, rp3y)
                r0 = rx[0] * ppfu
                r1 = rx[1] * ppfu

                if (hcode & 1) != 0 && r0.finite?
                  xcov += clamp(r0 + 0.5, 0.0, 1.0)
                  xwgt = [xwgt, clamp(1.0 - r0.abs * 2.0, 0.0, 1.0)].max
                end

                if hcode > 1 && r1.finite?
                  xcov -= clamp(r1 + 0.5, 0.0, 1.0)
                  xwgt = [xwgt, clamp(1.0 - r1.abs * 2.0, 0.0, 1.0)].max
                end
              end
            end

            # Banded: vertical ray
            v_bi = clamp(((sx - bands[:x_min]) / bands[:v_thickness]).floor, 0, bands[:num_v] - 1)
            bands[:v_bands][v_bi].each do |ci|
              c = curves[ci]
              b = bands[:curve_bounds][ci]

              break if (b[:max_y] - sy) * ppfu < -0.5

              rp1x = c[:p1][0] - sx; rp1y = c[:p1][1] - sy
              rp2x = c[:p2][0] - sx; rp2y = c[:p2][1] - sy
              rp3x = c[:p3][0] - sx; rp3y = c[:p3][1] - sy

              vcode = calc_root_code(rp1x, rp2x, rp3x)
              if vcode != 0
                ry = solve_vert_poly(rp1x, rp1y, rp2x, rp2y, rp3x, rp3y)
                r0 = ry[0] * ppfu
                r1 = ry[1] * ppfu

                if (vcode & 1) != 0 && r0.finite?
                  ycov -= clamp(r0 + 0.5, 0.0, 1.0)
                  ywgt = [ywgt, clamp(1.0 - r0.abs * 2.0, 0.0, 1.0)].max
                end

                if vcode > 1 && r1.finite?
                  ycov += clamp(r1 + 0.5, 0.0, 1.0)
                  ywgt = [ywgt, clamp(1.0 - r1.abs * 2.0, 0.0, 1.0)].max
                end
              end
            end
          else
            # Fallback: brute force all curves
            curves.each do |c|
              rp1x = c[:p1][0] - sx; rp1y = c[:p1][1] - sy
              rp2x = c[:p2][0] - sx; rp2y = c[:p2][1] - sy
              rp3x = c[:p3][0] - sx; rp3y = c[:p3][1] - sy

              unless c[:horiz]
                hcode = calc_root_code(rp1y, rp2y, rp3y)
                if hcode != 0
                  rx = solve_horiz_poly(rp1x, rp1y, rp2x, rp2y, rp3x, rp3y)
                  r0 = rx[0] * ppfu
                  r1 = rx[1] * ppfu
                  if (hcode & 1) != 0 && r0.finite?
                    xcov += clamp(r0 + 0.5, 0.0, 1.0)
                    xwgt = [xwgt, clamp(1.0 - r0.abs * 2.0, 0.0, 1.0)].max
                  end
                  if hcode > 1 && r1.finite?
                    xcov -= clamp(r1 + 0.5, 0.0, 1.0)
                    xwgt = [xwgt, clamp(1.0 - r1.abs * 2.0, 0.0, 1.0)].max
                  end
                end
              end

              unless c[:vert]
                vcode = calc_root_code(rp1x, rp2x, rp3x)
                if vcode != 0
                  ry = solve_vert_poly(rp1x, rp1y, rp2x, rp2y, rp3x, rp3y)
                  r0 = ry[0] * ppfu
                  r1 = ry[1] * ppfu
                  if (vcode & 1) != 0 && r0.finite?
                    ycov -= clamp(r0 + 0.5, 0.0, 1.0)
                    ywgt = [ywgt, clamp(1.0 - r0.abs * 2.0, 0.0, 1.0)].max
                  end
                  if vcode > 1 && r1.finite?
                    ycov += clamp(r1 + 0.5, 0.0, 1.0)
                    ywgt = [ywgt, clamp(1.0 - r1.abs * 2.0, 0.0, 1.0)].max
                  end
                end
              end
            end
          end

          coverage = calc_coverage(xcov, ycov, xwgt, ywgt)
          coverage = Math.sqrt(coverage) if stem_darkening && coverage > 0.0
          alpha = (coverage * 255).to_i

          idx = row * width + col
          pixels[idx] = alpha
        end
      end

      pixels
    end
  end

  class Font
    attr_reader :ascent, :descent, :line_gap, :units_per_em, :cap_height

    def initialize(path)
      data = $gtk.read_file(path)
      raise "Slug::Font: failed to read #{path}" unless data

      tables = TTF.parse_table_directory(data)
      head = TTF.parse_head(data, tables['head'])
      maxp = TTF.parse_maxp(data, tables['maxp'])
      hhea = TTF.parse_hhea(data, tables['hhea'])
      os2 = TTF.parse_os2(data, tables['OS/2'])

      @data = data
      @units_per_em = head[:units_per_em]
      @index_to_loc_format = head[:index_to_loc_format]
      @ascent = hhea[:ascent]
      @descent = hhea[:descent]
      @line_gap = hhea[:line_gap]
      @hmtx = TTF.parse_hmtx(data, tables['hmtx'], hhea[:num_h_metrics], maxp[:num_glyphs])
      @loca = TTF.parse_loca(data, tables['loca'], head[:index_to_loc_format], maxp[:num_glyphs])
      @cmap = TTF.parse_cmap(data, tables['cmap'])
      @glyf_offset = tables['glyf'][:offset]

      @glyph_cache = {}

      # Get cap height from OS/2 table, or estimate from 'H' glyph
      @cap_height = os2 && os2[:cap_height] ? os2[:cap_height] : estimate_cap_height
    end

    # Snap font size so cap height aligns to the pixel grid
    def snap_size(size_px)
      return size_px unless @cap_height && @cap_height > 0
      cap_px = size_px.to_f * @cap_height / @units_per_em
      snapped_cap = cap_px.round
      snapped_cap = 1 if snapped_cap < 1
      snapped_cap.to_f * @units_per_em / @cap_height
    end

    # Render text into a DragonRuby pixel array
    def render_text(args, name, text, size_px: 24, color: 0xFFFFFF, snap: true, stem_darkening: false)
      size_px = snap_size(size_px) if snap
      ppfu = size_px.to_f / @units_per_em
      ascent_px = (@ascent * ppfu).ceil
      descent_px = (-@descent * ppfu).ceil
      height = ascent_px + descent_px

      # Calculate total width
      total_advance_fu = 0
      text.each_char do |ch|
        gid = @cmap[:lookup].call(ch.ord)
        m = @hmtx[gid]
        total_advance_fu += m[:advance_width] if m
      end
      width = (total_advance_fu * ppfu).ceil + 1
      width = 1 if width < 1

      # Build pixel data in a local array
      pixels = Array.new(width * height, 0x00000000)

      # Extract color channels for ABGR
      cr = color & 0xFF
      cg = (color >> 8) & 0xFF
      cb = (color >> 16) & 0xFF

      # Render each glyph
      cursor_fu = 0.0
      text.each_char do |ch|
        gid = @cmap[:lookup].call(ch.ord)
        glyph = get_glyph(gid)
        m = @hmtx[gid]

        if glyph && glyph[:curves] && glyph[:curves].length > 0 && m
          gx_min = glyph[:x_min]
          gy_min = glyph[:y_min]
          gx_max = glyph[:x_max]
          gy_max = glyph[:y_max]

          glyph_w = ((gx_max - gx_min) * ppfu).ceil + 2
          glyph_h = ((gy_max - gy_min) * ppfu).ceil + 2

          if glyph_w > 0 && glyph_h > 0
            alphas = Rasterizer.rasterize_glyph(
              glyph[:curves], glyph_w, glyph_h, ppfu,
              gx_min.to_f, gy_min.to_f, stem_darkening
            )

            # Blit into local pixel array
            dest_x_start = ((cursor_fu + gx_min) * ppfu).round
            baseline_row = descent_px

            glyph_h.times do |grow|
              dy = baseline_row + (gy_min * ppfu).round + grow
              next if dy < 0 || dy >= height

              glyph_w.times do |gcol|
                alpha = alphas[grow * glyph_w + gcol]
                next if alpha == 0

                dx = dest_x_start + gcol
                next if dx < 0 || dx >= width

                dest_idx = (height - 1 - dy) * width + dx
                next if dest_idx < 0 || dest_idx >= width * height

                pixels[dest_idx] = (alpha << 24) | (cb << 16) | (cg << 8) | cr
              end
            end
          end
        end

        cursor_fu += m[:advance_width] if m
      end

      pa = args.pixel_array(name)
      pa.w = width
      pa.h = height
      pa.pixels = pixels

      [width, height]
    end

    def get_glyph(glyph_id)
      return @glyph_cache[glyph_id] if @glyph_cache.key?(glyph_id)
      TTF.parse_glyph(@data, @glyf_offset, @loca, glyph_id, @glyph_cache)
    end

    def estimate_cap_height
      gid = @cmap[:lookup].call('H'.ord)
      return nil if gid == 0
      glyph = get_glyph(gid)
      glyph ? glyph[:y_max] : nil
    end
  end
end
