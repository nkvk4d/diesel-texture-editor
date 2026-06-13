require 'gtk3'
require 'cairo'
require 'fileutils'
require 'json'
require 'zip'
require 'open-uri'
require 'stringio'

class DieselTextureEditor < Gtk::Window
  DEFAULT_HEADER = "\x00" * 16

  def initialize
    super("Diesel Texture Editor")
    set_default_size(1100, 750)
    set_window_position(:center)

    @stack = Gtk::Stack.new
    @stack.transition_type = :crossfade

    @header = nil
    @original_dds_format = nil
    @current_tool = :brush
    @current_color = [0, 0, 0, 1]
    @last_x = nil
    @last_y = nil
    @zoom_level = 1.0
    @brush_size = 5.0

    @is_panning = false
    @pan_start_x = nil
    @pan_start_y = nil
    @start_h = 0
    @start_v = 0

    @undo_stack = []
    @redo_stack = []
    @orig_image = nil
    @current_file_path = nil

    build_main_menu
    build_editor

    add(@stack)
    signal_connect("destroy") { Gtk.main_quit }
    show_all
  end

  # ==========================================
  # MAIN MENU
  # ==========================================
  def build_main_menu
    vbox = Gtk::Box.new(:vertical, 10)
    vbox.set_halign(:center)
    vbox.set_valign(:center)

    ascii_art = <<~'ASCII'
       ___  _             __  ______        __                 ____   ___ __
      / _ \(_)__ ___ ___ / / /_  __/____ __/ /___ _________   / __/__/ (_) /____  ____
     / // / / -_|_-</ -_) /   / / / -_) \ / __/ // / __/ -_) / _// _  / / __/ _ \/ __/
    /____/_/\__/___/\__/_/   /_/  \__/_\_\\__/\_,_/_/  \__/ /___/\_,_/_/\__/\___/_/
    ASCII

    ascii_label = Gtk::Label.new(ascii_art)
    ascii_label.override_font(Pango::FontDescription.new('Monospace 10'))

    title_label = Gtk::Label.new
    title_label.set_markup("<span size='x-large' weight='bold'>Welcome to Diesel Texture Editor!</span>")

    btn_box = Gtk::Box.new(:horizontal, 10)
    btn_box.set_halign(:center)

    open_btn = Gtk::Button.new(label: "Open File Chooser")
    create_btn = Gtk::Button.new(label: "Create")

    open_btn.signal_connect("clicked") { select_file_dialog }
    create_btn.signal_connect("clicked") do
      @header = DEFAULT_HEADER
      @original_dds_format = nil
      @orig_image = nil
      @current_file_path = "New File"
      @undo_stack.clear
      @redo_stack.clear
      init_canvas
      save_state
      @stack.set_visible_child_name("editor")
    end

    btn_box.pack_start(open_btn, expand: false, fill: false, padding: 0)
    btn_box.pack_start(create_btn, expand: false, fill: false, padding: 0)

    path_box = Gtk::Box.new(:horizontal, 5)
    path_box.set_halign(:center)
    @path_entry = Gtk::Entry.new
    @path_entry.width_chars = 40
    @path_entry.placeholder_text = "Enter path to file..."

    select_btn = Gtk::Button.new(label: "Select Path")
    select_btn.signal_connect("clicked") do
      path = @path_entry.text.strip
      if File.exist?(path) && !File.directory?(path)
        load_file(path)
        @stack.set_visible_child_name("editor")
      else
        show_message("Invalid file path!", :error)
      end
    end

    path_box.pack_start(@path_entry, expand: false, fill: false, padding: 0)
    path_box.pack_start(select_btn, expand: false, fill: false, padding: 0)

    vbox.pack_start(ascii_label, expand: false, fill: false, padding: 0)
    vbox.pack_start(title_label, expand: false, fill: false, padding: 15)
    vbox.pack_start(btn_box, expand: false, fill: false, padding: 5)
    vbox.pack_start(path_box, expand: false, fill: false, padding: 5)

    @stack.add_named(vbox, "main_menu")
  end

  def select_file_dialog
    dialog = Gtk::FileChooserDialog.new(
      title: "Select .texture or Image file",
      parent: self,
      action: :open,
      buttons: [["_Cancel", :cancel], ["_Open", :accept]]
    )
    res = dialog.run
    filename = dialog.filename
    dialog.destroy

    if res == :accept && filename
      @path_entry.text = filename
      load_file(filename)
      @stack.set_visible_child_name("editor")
    end
  end

  # ==========================================
  # TOOL MANAGEMENT & DOWNLOADER
  # ==========================================
  def has_crunch?
    File.exist?("crunch.exe") || File.exist?("crunch_x64.exe")
  end

  def ensure_tools_available
    has_texconv = File.exist?("texconv.exe")
    im_exe = system("command -v magick > /dev/null 2>&1") ? "magick" : "convert"
    has_im = system("command -v #{im_exe} > /dev/null 2>&1")

    return true if has_crunch? || has_texconv || has_im

    show_tools_dialog

    has_texconv = File.exist?("texconv.exe")
    has_im = system("command -v #{im_exe} > /dev/null 2>&1")
    has_crunch? || has_texconv || has_im
  end

  def show_tools_dialog
    dialog = Gtk::Dialog.new(
      title: "Missing Tools",
      parent: self,
      flags: [:modal, :destroy_with_parent],
      buttons: [["Ready", :accept]]
    )
    dialog.set_default_size(500, 300)
    vbox = dialog.content_area

    lbl = Gtk::Label.new("Conversion tools not found! Please download at least one to handle DDS formats:")
    vbox.pack_start(lbl, expand: false, fill: false, padding: 10)

    btn_cr = Gtk::Button.new(label: "Download Crunch x64 (Requires Wine)")
    btn_cr.signal_connect("clicked") { download_tool("https://raw.githubusercontent.com/richgel999/crunch-1/master/bin/crunch_x64.exe", "crunch_x64.exe", btn_cr) }
    vbox.pack_start(btn_cr, expand: false, fill: false, padding: 5)

    btn_tx = Gtk::Button.new(label: "Download Texconv (Requires Wine)")
    btn_tx.signal_connect("clicked") { download_tool("https://github.com/Microsoft/DirectXTex/releases/latest/download/texconv.exe", "texconv.exe", btn_tx) }
    vbox.pack_start(btn_tx, expand: false, fill: false, padding: 5)

    distro_cmd = "sudo apt install imagemagick"
    if File.exist?('/etc/os-release')
      os_info = File.read('/etc/os-release')
      distro_cmd = "sudo dnf install imagemagick" if os_info =~ /fedora|rhel|centos|almalinux|rocky/i
      distro_cmd = "sudo pacman -S imagemagick" if os_info =~ /arch|manjaro/i
      distro_cmd = "sudo zypper install imagemagick" if os_info =~ /suse/i
    end

    lbl_im = Gtk::Label.new("Or install ImageMagick natively (Warning: Mipmaps may break):\n#{distro_cmd}")
    lbl_im.set_line_wrap(true)
    lbl_im.set_justify(Gtk::Justification::CENTER)
    vbox.pack_start(lbl_im, expand: false, fill: false, padding: 15)

    dialog.show_all
    dialog.run
    dialog.destroy
  end

  def download_tool(url_str, dest, btn)
    btn.label = "Downloading..."
    btn.sensitive = false
    Thread.new do
      begin
        URI.open(url_str, 'rb') do |remote|
          File.binwrite(dest, remote.read)
        end
        GLib::Idle.add do
          btn.label = "Downloaded #{dest}!"
          false
        end
      rescue => e
        GLib::Idle.add do
          btn.label = "Error downloading"
          btn.sensitive = true
          false
        end
      end
    end
  end

  def convert_dds_to_png(input_dds, output_png)
    if has_crunch?
      exe = File.exist?("crunch_x64.exe") ? "crunch_x64.exe" : "crunch.exe"
      system("wine #{exe} -file #{input_dds} -out #{output_png}")
    elsif File.exist?("texconv.exe")
      system("wine texconv.exe #{input_dds} -ft png -o .")
    else
      im_exe = system("command -v magick > /dev/null 2>&1") ? "magick" : "convert"
      if system("command -v #{im_exe} > /dev/null 2>&1")
        system("#{im_exe} #{input_dds} #{output_png}")
      else
        show_message("No conversion tool available!", :error)
      end
    end
  end

  # ==========================================
  # EDITOR INTERFACE & LOGIC
  # ==========================================
  def build_editor
    main_hbox = Gtk::Box.new(:horizontal, 5)

    tools_vbox = Gtk::Box.new(:vertical, 5)
    tools_vbox.set_size_request(150, -1)

    color_btn = Gtk::ColorButton.new
    hex_entry = Gtk::Entry.new
    hex_entry.placeholder_text = "#000000"

    color_btn.signal_connect("color-set") do |cb|
      r, g, b = cb.rgba.red, cb.rgba.green, cb.rgba.blue
      @current_color = [r, g, b, 1]
      hex_entry.text = sprintf("#%02X%02X%02X", r * 255, g * 255, b * 255)
    end

    brush_btn = Gtk::Button.new(label: "Brush")
    eraser_btn = Gtk::Button.new(label: "Eraser")
    fill_btn = Gtk::Button.new(label: "Fill")

    brush_btn.signal_connect("clicked") { @current_tool = :brush }
    eraser_btn.signal_connect("clicked") { @current_tool = :eraser }
    fill_btn.signal_connect("clicked") { @current_tool = :fill }

    undo_btn = Gtk::Button.new(label: "Undo (Back)")
    redo_btn = Gtk::Button.new(label: "Redo (Forward)")
    undo_btn.signal_connect("clicked") { undo_action }
    redo_btn.signal_connect("clicked") { redo_action }

    brush_size_spin = Gtk::SpinButton.new(1.0, 100.0, 1.0)
    brush_size_spin.value = @brush_size
    brush_size_spin.signal_connect("value-changed") { |w| @brush_size = w.value }

    zoom_scale = Gtk::Scale.new(:horizontal, 1.0, 20.0, 1.0)
    zoom_scale.value = @zoom_level
    zoom_scale.signal_connect("value-changed") do |w|
      @zoom_level = w.value
      if @surface
        @drawing_area.set_size_request(@surface.width * @zoom_level, @surface.height * @zoom_level)
        @drawing_area.queue_draw
      end
    end

    tools_vbox.pack_start(Gtk::Label.new("Tools"), expand: false, fill: false, padding: 5)
    tools_vbox.pack_start(undo_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(redo_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(color_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(hex_entry, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(brush_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(eraser_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(fill_btn, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(Gtk::Label.new("Brush Size"), expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(brush_size_spin, expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(Gtk::Label.new("Zoom & Pan (RMB)"), expand: false, fill: false, padding: 2)
    tools_vbox.pack_start(zoom_scale, expand: false, fill: false, padding: 2)

    canvas_frame = Gtk::Frame.new("Image Canvas")

    @canvas_scroll = Gtk::ScrolledWindow.new
    @canvas_scroll.set_policy(:automatic, :automatic)

    @drawing_area = Gtk::DrawingArea.new
    @drawing_area.add_events(Gdk::EventMask::BUTTON_PRESS_MASK |
                             Gdk::EventMask::POINTER_MOTION_MASK |
                             Gdk::EventMask::BUTTON_RELEASE_MASK |
                             Gdk::EventMask::SCROLL_MASK)

    @drawing_area.signal_connect("draw") { |w, cr| draw_canvas(w, cr) }
    @drawing_area.signal_connect("configure-event") { init_canvas }
    @drawing_area.signal_connect("button-press-event") { |w, e| start_draw(e) }
    @drawing_area.signal_connect("motion-notify-event") { |w, e| do_draw(e) }
    @drawing_area.signal_connect("button-release-event") { |w, e| end_draw(e) }

    @canvas_scroll.add(@drawing_area)
    canvas_frame.add(@canvas_scroll)

    right_vbox = Gtk::Box.new(:vertical, 5)
    right_vbox.set_size_request(280, -1)

    hex_frame = Gtk::Frame.new("Image Header")
    hex_vbox = Gtk::Box.new(:vertical, 2)
    @hex_textview = Gtk::TextView.new
    @hex_textview.override_font(Pango::FontDescription.new('Monospace 9'))
    @hex_textview.wrap_mode = Gtk::WrapMode::CHAR

    hex_scroll = Gtk::ScrolledWindow.new
    hex_scroll.add(@hex_textview)
    hex_scroll.set_size_request(-1, 150)

    apply_hex_btn = Gtk::Button.new(label: "why do i exist")
    apply_hex_btn.signal_connect("clicked") { apply_hex_to_surface }

    hex_vbox.pack_start(hex_scroll, expand: true, fill: true, padding: 0)
    hex_vbox.pack_start(apply_hex_btn, expand: false, fill: false, padding: 0)
    hex_frame.add(hex_vbox)

    files_frame = Gtk::Frame.new("Project Files")
    @file_store = Gtk::ListStore.new(String)
    @tree_view = Gtk::TreeView.new(@file_store)
    @tree_view.append_column(Gtk::TreeViewColumn.new("Filename", Gtk::CellRendererText.new, text: 0))
    files_scroll = Gtk::ScrolledWindow.new
    files_scroll.add(@tree_view)
    files_frame.add(files_scroll)

    action_box = Gtk::Box.new(:horizontal, 5)
    save_btn = Gtk::Button.new(label: "Save Project (.jar)")
    export_btn = Gtk::Button.new(label: "Export (.texture)")

    save_btn.signal_connect("clicked") { save_project }
    export_btn.signal_connect("clicked") { show_export_dialog }

    action_box.pack_start(save_btn, expand: true, fill: true, padding: 0)
    action_box.pack_start(export_btn, expand: true, fill: true, padding: 0)

    credit_box = Gtk::Box.new(:horizontal, 0)
    credit_btn = Gtk::Button.new
    credit_btn.add(Gtk::Label.new.set_markup("<span size='small' foreground='gray'>credit</span>"))
    credit_btn.set_relief(Gtk::ReliefStyle::NONE)
    credit_btn.set_halign(:end)
    credit_btn.signal_connect("clicked") { show_message("by nkvk4d", :info) }
    credit_box.pack_end(credit_btn, expand: false, fill: false, padding: 0)

    right_vbox.pack_start(hex_frame, expand: false, fill: true, padding: 2)
    right_vbox.pack_start(files_frame, expand: true, fill: true, padding: 2)
    right_vbox.pack_start(action_box, expand: false, fill: false, padding: 5)
    right_vbox.pack_start(credit_box, expand: false, fill: false, padding: 0)

    main_hbox.pack_start(tools_vbox, expand: false, fill: true, padding: 5)
    main_hbox.pack_start(canvas_frame, expand: true, fill: true, padding: 5)
    main_hbox.pack_start(right_vbox, expand: false, fill: true, padding: 5)

    @stack.add_named(main_hbox, "editor")
  end

  # ==========================================
  # CAIRO DRAWING LOGIC & UNDO/REDO
  # ==========================================
  def init_canvas
    return true if @surface

    width = @drawing_area.allocated_width
    height = @drawing_area.allocated_height
    width = 512 if width <= 1
    height = 512 if height <= 1

    @surface = Cairo::ImageSurface.new(Cairo::FORMAT_ARGB32, width, height)
    cr = Cairo::Context.new(@surface)
    cr.set_source_rgba(1, 1, 1, 1)
    cr.paint
    true
  end

  def draw_canvas(widget, cr)
    return unless @surface
    cr.scale(@zoom_level, @zoom_level)
    cr.set_source(@surface, 0, 0)
    cr.source.filter = Cairo::Filter::NEAREST rescue nil
    cr.paint
  end

  def start_draw(event)
    if event.button == 3 || event.button == 2
      @is_panning = true
      @pan_start_x = event.x_root
      @pan_start_y = event.y_root

      @hadj = @canvas_scroll.hadjustment
      @vadj = @canvas_scroll.vadjustment
      @start_h = @hadj.value
      @start_v = @vadj.value
      return
    end

    @last_x = event.x / @zoom_level
    @last_y = event.y / @zoom_level

    if @current_tool == :fill
      fill_canvas_area(@last_x, @last_y)
      @last_x = @last_y = nil
    else
      @drawing_happened = false
    end
  end

  def do_draw(event)
    if @is_panning
      dx = @pan_start_x - event.x_root
      dy = @pan_start_y - event.y_root
      @hadj.value = @start_h + dx
      @vadj.value = @start_v + dy
      return
    end

    return unless @last_x && @last_y && @surface && @current_tool != :fill
    cr = Cairo::Context.new(@surface)

    if @current_tool == :eraser
      cr.operator = Cairo::OPERATOR_CLEAR
      cr.set_source_rgba(0, 0, 0, 0)
    else
      cr.set_source_rgba(*@current_color)
    end

    cr.set_line_width(@brush_size)
    cr.set_line_cap(Cairo::LINE_CAP_ROUND)
    cr.move_to(@last_x, @last_y)

    current_x = event.x / @zoom_level
    current_y = event.y / @zoom_level

    cr.line_to(current_x, current_y)
    cr.stroke

    @last_x, @last_y = current_x, current_y
    @drawing_happened = true
    @drawing_area.queue_draw

    update_hex_view
  end

  def end_draw(event)
    if @is_panning && (event.button == 3 || event.button == 2)
      @is_panning = false
      return
    end

    if @drawing_happened
      save_state
    end
    @last_x = @last_y = nil
  end

  def fill_canvas_area(start_x, start_y)
    return unless @surface
    @surface.flush
    data = @surface.data.dup
    width = @surface.width
    height = @surface.height
    stride = @surface.stride

    start_x = start_x.to_i
    start_y = start_y.to_i
    return if start_x < 0 || start_x >= width || start_y < 0 || start_y >= height

    idx = start_y * stride + start_x * 4

    tb = data.getbyte(idx)
    tg = data.getbyte(idx+1)
    tr = data.getbyte(idx+2)
    ta = data.getbyte(idx+3)

    fb = (@current_color[2] * 255).to_i
    fg = (@current_color[1] * 255).to_i
    fr = (@current_color[0] * 255).to_i
    fa = (@current_color[3] * 255).to_i

    return if tb == fb && tg == fg && tr == fr && ta == fa

    queue = [[start_x, start_y]]

    while !queue.empty?
      cx, cy = queue.pop
      idx = cy * stride + cx * 4
      if data.getbyte(idx) == tb && data.getbyte(idx+1) == tg && data.getbyte(idx+2) == tr && data.getbyte(idx+3) == ta
        data.setbyte(idx, fb)
        data.setbyte(idx+1, fg)
        data.setbyte(idx+2, fr)
        data.setbyte(idx+3, fa)
        queue << [cx+1, cy] if cx+1 < width
        queue << [cx-1, cy] if cx > 0
        queue << [cx, cy+1] if cy+1 < height
        queue << [cx, cy-1] if cy > 0
      end
    end

    @surface = Cairo::ImageSurface.new(data, Cairo::FORMAT_ARGB32, width, height, stride)
    @drawing_area.queue_draw
    save_state
    update_hex_view
  end

  def save_state
    sio = StringIO.new
    @surface.write_to_png(sio)
    @undo_stack << sio.string
    @redo_stack.clear
  end

  def undo_action
    if @undo_stack.size > 1
      @redo_stack << @undo_stack.pop
      restore_state(@undo_stack.last)
    end
  end

  def redo_action
    if !@redo_stack.empty?
      state = @redo_stack.pop
      @undo_stack << state
      restore_state(state)
    end
  end

  def restore_state(png_data)
    File.binwrite("temp_state.png", png_data)
    @surface = Cairo::ImageSurface.from_png("temp_state.png")
    @drawing_area.queue_draw
    update_hex_view
    File.delete("temp_state.png")
  end

  def update_hex_view
    return unless @surface
    @surface.flush
    bytes = @surface.data[0...256]
    hex_str = bytes.unpack('H2' * bytes.bytesize).join(' ').upcase
    @hex_textview.buffer.text = hex_str
  end

  def apply_hex_to_surface
    return unless @surface
    hex_str = @hex_textview.buffer.text.gsub(/\s+/, '')
    return if hex_str.empty?

    bytes = [hex_str].pack('H*')
    @surface.flush
    data = @surface.data.dup
    data[0...bytes.bytesize] = bytes

    @surface = Cairo::ImageSurface.new(data, Cairo::FORMAT_ARGB32, @surface.width, @surface.height, @surface.stride)
    @drawing_area.queue_draw
    save_state
  end

  # ==========================================
  # FILE PARSING (.texture)
  # ==========================================
  def detect_dds_format(dds_data)
    return :rgba8 if dds_data.bytesize < 128
    four_cc = dds_data[84, 4]
    if four_cc == "DXT5" || four_cc == "DXT1" || four_cc == "DXT3"
      :dxt5
    else
      :rgba8
    end
  end

  def extract_header_and_format(content)
    dds_idx = content.index("DDS ")
    if dds_idx && dds_idx > 0
      format = detect_dds_format(content[dds_idx..-1])
      return content[0...dds_idx], format
    elsif dds_idx == 0
      return "", detect_dds_format(content)
    end

    w = content[4, 4]&.unpack1('V') || 0
    h = content[8, 4]&.unpack1('V') || 0
    if w > 0 && h > 0
      payload_size = w * h * 4
      expected_header_size = content.bytesize - payload_size
      if expected_header_size > 0 && expected_header_size < content.bytesize
        return content[0...expected_header_size], :rgba8
      end
    end

    [content[0...16] || DEFAULT_HEADER, :rgba8]
  end

  def load_file(path)
    return unless File.exist?(path)
    @current_file_path = path
    @file_store.clear

    dir = File.dirname(path)
    Dir.entries(dir).each do |f|
      next if f.start_with?('.')
      @file_store.append[0] = f
    end

    @header = DEFAULT_HEADER
    @original_dds_format = nil
    @surface = nil
    @undo_stack.clear
    @redo_stack.clear
    @orig_image = nil

    if path.end_with?('.texture') || path.end_with?('.dds')
      ensure_tools_available
      content = File.binread(path)

      @header, @original_dds_format = extract_header_and_format(content)
      dds_idx = content.index("DDS ")

      if dds_idx
        dds_data = content[dds_idx..-1]

        temp_dds = "temp_load.dds"
        temp_png = "temp_load.png"
        File.binwrite(temp_dds, dds_data)

        convert_dds_to_png(temp_dds, temp_png)

        if File.exist?(temp_png)
          @surface = Cairo::ImageSurface.from_png(temp_png)
          @orig_image = File.binread(temp_png)
          save_state
          @drawing_area.set_size_request(@surface.width * @zoom_level, @surface.height * @zoom_level)
          @drawing_area.queue_draw
          update_hex_view
          File.delete(temp_png)
        else
          show_message("Failed to convert DDS to PNG for rendering.", :error)
        end
        File.delete(temp_dds) if File.exist?(temp_dds)
      else
        raw_data = content[@header.bytesize..-1] || ""

        payload_size = raw_data.bytesize
        w = @header[4, 4]&.unpack1('V') rescue 0
        h = @header[8, 4]&.unpack1('V') rescue 0

        if w.nil? || h.nil? || w <= 0 || h <= 0 || w * h * 4 != payload_size
          num_pixels = payload_size / 4
          w = Math.sqrt(num_pixels).to_i
          h = w
        end

        if w > 0 && h > 0 && w * h * 4 == payload_size
          temp_raw = "temp_load.raw"
          temp_png = "temp_load.png"
          File.binwrite(temp_raw, raw_data)

          exe = system("command -v magick > /dev/null 2>&1") ? "magick" : "convert"
          system("#{exe} -size #{w}x#{h} -depth 8 rgba:#{temp_raw} #{temp_png}")

          if File.exist?(temp_png)
            @surface = Cairo::ImageSurface.from_png(temp_png)
            @orig_image = File.binread(temp_png)
            save_state
            @drawing_area.set_size_request(@surface.width * @zoom_level, @surface.height * @zoom_level)
            @drawing_area.queue_draw
            update_hex_view
            File.delete(temp_png)
          else
            show_message("Failed to convert raw RGBA8 to PNG for rendering.", :error)
          end
          File.delete(temp_raw) if File.exist?(temp_raw)
        else
          show_message("No DDS magic bytes found and invalid raw RGBA8 payload size!", :warning)
        end
      end
    else
      @surface = Cairo::ImageSurface.from_png(path)
      @orig_image = File.binread(path)
      save_state
      @drawing_area.set_size_request(@surface.width * @zoom_level, @surface.height * @zoom_level)
      @drawing_area.queue_draw
      update_hex_view
    end
  end

  # ==========================================
  # SAVE & EXPORT (JSON/JAR & DXT5/RGBA8)
  # ==========================================
  def save_project
    return unless @surface

    dialog = Gtk::FileChooserDialog.new(
      title: "Save Project As",
      parent: self,
      action: :save,
      buttons: [["_Cancel", :cancel], ["_Save", :accept]]
    )
    dialog.do_overwrite_confirmation = true
    dialog.current_name = "project.jar"

    res = dialog.run
    save_path = dialog.filename
    dialog.destroy

    if res == :accept
      save_path += ".jar" unless save_path.end_with?(".jar")
      File.delete(save_path) if File.exist?(save_path)

      project_data = {
        editor: "Diesel Texture Editor",
        version: "1.0",
        history_count: @undo_stack.size,
        file: "project_layer.png",
        original: @orig_image ? "original_layer.png" : nil
      }

      begin
        Zip::File.open(save_path, Zip::File::CREATE) do |zipfile|
          zipfile.get_output_stream("project.json") { |f| f.write(project_data.to_json) }

          sio = StringIO.new
          @surface.write_to_png(sio)
          zipfile.get_output_stream("project_layer.png") { |f| f.write(sio.string) }

          if @orig_image
            zipfile.get_output_stream("original_layer.png") { |f| f.write(@orig_image) }
          end

          @undo_stack.each_with_index do |state, i|
            zipfile.get_output_stream("history_#{i}.png") { |f| f.write(state) }
          end
        end
        show_message("Project securely saved to #{save_path} without loose files.", :info)
      rescue => e
        show_message("Failed to save project: #{e.message}", :error)
      end
    end
  end

  def show_export_dialog
    ensure_tools_available
    dialog = Gtk::Dialog.new(
      title: "Export Settings",
      parent: self,
      flags: [:modal, :destroy_with_parent],
      buttons: [["Cancel", :cancel], ["Export", :accept]]
    )

    vbox = dialog.content_area

    header_frame = Gtk::Frame.new("Original .texture for header (Required)")
    header_box = Gtk::Box.new(:horizontal, 5)

    header_entry = Gtk::Entry.new
    header_entry.set_hexpand(true)
    if @current_file_path && File.exist?(@current_file_path) && @current_file_path.end_with?('.texture')
      header_entry.text = @current_file_path
    end

    browse_btn = Gtk::Button.new(label: "Browse...")
    browse_btn.signal_connect("clicked") do
      ch_dialog = Gtk::FileChooserDialog.new(
        title: "Select original .texture for header",
        parent: dialog,
        action: :open,
        buttons: [["_Cancel", :cancel], ["_Open", :accept]]
      )
      if ch_dialog.run == :accept
        header_entry.text = ch_dialog.filename
      end
      ch_dialog.destroy
    end

    header_box.pack_start(header_entry, expand: true, fill: true, padding: 5)
    header_box.pack_start(browse_btn, expand: false, fill: false, padding: 5)
    header_frame.add(header_box)
    vbox.pack_start(header_frame, expand: false, fill: false, padding: 5)

    tool_frame = Gtk::Frame.new("Conversion Tool")
    tool_box = Gtk::Box.new(:vertical, 5)
    radio_crunch = Gtk::RadioButton.new(label: "Crunch (wine crunch.exe / crunch_x64.exe)")
    radio_texconv = Gtk::RadioButton.new(member: radio_crunch, label: "Texconv (wine texconv.exe)")
    radio_imagemagick = Gtk::RadioButton.new(member: radio_crunch, label: "ImageMagick (Native) - Warn: Mipmaps may break")
    tool_box.pack_start(radio_crunch, expand: false, fill: false, padding: 2)
    tool_box.pack_start(radio_texconv, expand: false, fill: false, padding: 2)
    tool_box.pack_start(radio_imagemagick, expand: false, fill: false, padding: 2)
    tool_frame.add(tool_box)
    vbox.pack_start(tool_frame, expand: false, fill: false, padding: 5)

    format_frame = Gtk::Frame.new("Compression Format")
    format_box = Gtk::Box.new(:vertical, 5)
    radio_auto = Gtk::RadioButton.new(label: "Automatically")
    radio_dxt5 = Gtk::RadioButton.new(member: radio_auto, label: "DXT5 (BC3)")
    radio_rgba8 = Gtk::RadioButton.new(member: radio_auto, label: "Uncompressed (RGBA8)")
    format_box.pack_start(radio_auto, expand: false, fill: false, padding: 2)
    format_box.pack_start(radio_dxt5, expand: false, fill: false, padding: 2)
    format_box.pack_start(radio_rgba8, expand: false, fill: false, padding: 2)
    format_frame.add(format_box)
    vbox.pack_start(format_frame, expand: false, fill: false, padding: 5)

    dialog.show_all

    res = dialog.run
    tool = radio_crunch.active? ? :crunch : (radio_texconv.active? ? :texconv : :imagemagick)
    header_path = header_entry.text.strip

    if res == :accept
      if !header_path.empty? && File.exist?(header_path)
        content = File.binread(header_path)
        @header, @original_dds_format = extract_header_and_format(content)
      end

      selected_format = if radio_auto.active?
                          @original_dds_format || :dxt5
                        elsif radio_dxt5.active?
                          :dxt5
                        else
                          :rgba8
                        end

      if !radio_auto.active? && @original_dds_format && selected_format != @original_dds_format
        warn_dialog = Gtk::MessageDialog.new(
          parent: dialog,
          flags: :modal,
          type: :warning,
          buttons: :ok_cancel,
          message: "Alert: Your selected format differs from the original file!\nIt is recommended to click Cancel to change it, but you can continue by clicking OK."
        )
        warn_res = warn_dialog.run
        warn_dialog.destroy
        if warn_res != :ok
          dialog.destroy
          return
        end
      end

      dialog.destroy
      export_texture(tool, selected_format)
    else
      dialog.destroy
    end
  end

  def export_texture(tool, format)
    return unless @surface
    input_png = "temp_export.png"
    output_payload = "temp_export.bin"

    @surface.write_to_png(input_png)
    File.delete(output_payload) if File.exist?(output_payload)

    success = false

    if format == :rgba8
      exe = system("command -v magick > /dev/null 2>&1") ? "magick" : "convert"
      success = system("#{exe} #{input_png} -depth 8 rgba:#{output_payload}")
      if !success
        show_message("Raw RGBA8 export requires ImageMagick.", :error)
        File.delete(input_png) if File.exist?(input_png)
        return
      end
    else
      case tool
      when :crunch
        exe = File.exist?("crunch_x64.exe") ? "crunch_x64.exe" : "crunch.exe"
        if format == :dxt5
          success = system("wine #{exe} -file #{input_png} -dxt5 -out #{output_payload}")
        else
          success = system("wine #{exe} -file #{input_png} -out #{output_payload}")
        end
      when :texconv
        fmt_flag = format == :dxt5 ? "DXT5" : "R8G8B8A8_UNORM"
        success = system("wine texconv.exe #{input_png} -f #{fmt_flag} -ft dds -o .")
        if success
          if File.exist?("temp_export.dds")
            File.rename("temp_export.dds", output_payload)
          elsif File.exist?("temp_export.DDS")
            File.rename("temp_export.DDS", output_payload)
          end
        end
      when :imagemagick
        unless system("command -v magick > /dev/null 2>&1") || system("command -v convert > /dev/null 2>&1")
          os_info = File.read('/etc/os-release') rescue ""
          distro = os_info =~ /fedora|rhel|centos|almalinux|rocky/i ? "sudo dnf" : (os_info =~ /arch|manjaro/i ? "sudo pacman -S" : "sudo apt")
          show_message("ImageMagick not found! Run: #{distro} install imagemagick", :error)
          return false
        end
        exe = system("command -v magick > /dev/null 2>&1") ? "magick" : "convert"
        fmt_flag = "dxt5"
        success = system("#{exe} #{input_png} -strip -define dds:compression=#{fmt_flag} #{output_payload}")
      end
    end

    if success && File.exist?(output_payload)
      hdr = @header || DEFAULT_HEADER
      w = @surface.width
      h = @surface.height

      if hdr.bytesize < 16
        hdr = [0, w, h, 0].pack('V*')
      else
        hdr = hdr.dup
        if hdr.bytesize >= 12
          hdr[4, 4] = [w].pack('V')
          hdr[8, 4] = [h].pack('V')
        end
      end

      payload_content = File.binread(output_payload)

      if format == :dxt5 && tool == :imagemagick && payload_content.bytesize >= 128
        header_part = payload_content[0...128]
        if header_part.include?("IMAGEMAGICK")
          header_part.gsub!("IMAGEMAGICK", "\x00" * 11)
          payload_content[0...128] = header_part
        end
      end

      File.open("final_mod.texture", "wb") do |f|
        f.write(hdr)
        f.write(payload_content)
      end
      show_message("Exported successfully to final_mod.texture!", :info)
    else
      show_message("Export failed. Check terminal for tool errors.", :error)
    end

    File.delete(input_png) if File.exist?(input_png)
    File.delete(output_payload) if File.exist?(output_payload)
  end

  def show_message(text, type)
    dialog = Gtk::MessageDialog.new(parent: self, flags: :modal, type: type, buttons: :ok, message: text)
    dialog.run
    dialog.destroy
  end
end

DieselTextureEditor.new
Gtk.main
