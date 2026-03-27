require_relative 'slug.rb'

FONT_PATH = 'fonts/font.ttf'
SIZES = [48, 32, 20]
TEXT = 'The quick brown fox jumps over the lazy dog'

def tick(args)
  if Kernel.tick_count == 0
    args.state.font = Slug::Font.new(FONT_PATH)
    puts "cap_height: #{args.state.font.cap_height}"
    args.state.rows = []

    y = 625
    SIZES.each_with_index do |sz, i|
      name = :"slug_#{sz}"
      t = Time.now
      w, h = args.state.font.render_text(args, name, TEXT, size_px: sz)
      elapsed = Time.now - t
      snapped = args.state.font.snap_size(sz)
      puts "Slug #{sz}px (snapped: #{snapped.round(2)}): #{elapsed.round(3)}s (#{w}x#{h})"

      bw, bh = GTK.calcstringbox(TEXT, size_px: sz, font: FONT_PATH)

      args.state.rows << { name: name, w: w, h: h, sz: sz, y: y, bw: bw.ceil, bh: bh.ceil }
      y -= h + bh.ceil + sz + 30
    end
  end

  args.outputs.background_color = [30, 30, 30]

  if args.state.rows
    args.state.rows.each do |r|
      args.outputs.sprites << { x: 30, y: r[:y], w: r[:w], h: r[:h], path: r[:name] }

      args.outputs.labels << {
        x: 30, y: r[:y] - 2,
        text: TEXT,
        size_px: r[:sz],
        font: FONT_PATH,
        r: 255, g: 255, b: 255
      }

      args.outputs.labels << {
        x: 1200, y: r[:y] + r[:h] - 5,
        text: "#{r[:sz]}px",
        size_px: 14, r: 128, g: 128, b: 128,
        anchor_x: 1.0
      }
    end

    args.outputs.labels << { x: 30, y: 710, text: 'Slug (top) vs Built-in (bottom)',
                             size_px: 16, r: 180, g: 180, b: 180 }
  end

  args.outputs.labels << {
    x: 1270, y: 710,
    text: "FPS: #{GTK.current_framerate.round}",
    size_px: 16, r: 100, g: 100, b: 100, anchor_x: 1.0
  }
end
