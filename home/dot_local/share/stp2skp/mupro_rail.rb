# Resize a segmented rail to an arbitrary length, inside SketchUp.
#
# The rail is built from rigid links laid at a fixed pitch, so its length is
# normally locked to multiples of that pitch. This rebuilds it as N whole links
# plus a final link cropped to the remainder - what happens when a real rail is
# sawn to length - and moves the end cap to the new end.
#
# Right-click a rail > "Set rail length...", or Extensions > Rail > Set length.
#
# Two rules learned the hard way, do not break them:
#  * Measure ALL geometry BEFORE make_unique. It invalidates sub-entity
#    references, and reading .bounds on a stale one crashes SketchUp inside
#    CComponent::ComputeBounds - not rescuable in Ruby.
#  * Pitch comes from the SPACING between links, never from a link's own width.
#    Here links are 40.015mm wide but sit on a 40.000mm pitch; using the width
#    accumulated 0.22mm of error over a 560mm rail.

require 'sketchup.rb'

module MuproRail
  TOL = 0.05  # mm; a remainder below this is not worth a link

  def self.definition_of(obj)
    obj.respond_to?(:definition) ? obj.definition : nil
  rescue StandardError
    nil
  end

  # Measure the rail. Returns a plain-data hash - no live entity references -
  # so it stays valid across make_unique.
  def self.analyse(definition)
    kids = definition.entities.select do |e|
      e.valid? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance))
    end
    return nil if kids.size < 2

    measured = kids.map do |k|
      { :obj => k, :defn => definition_of(k),
        :x0 => k.bounds.min.x, :w => k.bounds.width }
    end

    by_width = measured.group_by { |m| m[:w].round(3) }
    _w, family = by_width.max_by { |_k, list| list.size }
    return nil if family.size < 2

    family = family.sort_by { |m| m[:x0] }
    template_def = family.first[:defn]
    return nil if template_def.nil?

    # Pitch from consecutive spacing, not from link width.
    gaps = family.each_cons(2).map { |a, b| b[:x0] - a[:x0] }
    pitch = gaps.empty? ? family.first[:w] : gaps.min

    others = measured - family
    { :template_name => template_def.name,
      :pitch => pitch,
      :link_w => family.first[:w],
      :origin => family.first[:x0],
      :count => family.size,
      :caps => others.map { |m| { :name => m[:defn] && m[:defn].name,
                                  :x0 => m[:x0], :w => m[:w] } } }
  end

  # Face every closed loop of edges lying in the plane x = px.
  def self.cap_plane(entities, px, tol = 0.001)
    on_plane = entities.grep(Sketchup::Edge).select do |e|
      (e.start.position.x - px).abs < tol && (e.end.position.x - px).abs < tol
    end
    return 0 if on_plane.empty?

    remaining = on_plane.dup
    made = 0
    until remaining.empty?
      edge = remaining.shift
      loop_edges = [edge]
      head = edge.end
      tail = edge.start
      progress = true
      while progress && head != tail
        progress = false
        remaining.each do |e|
          if e.start == head
            head = e.end
          elsif e.end == head
            head = e.start
          else
            next
          end
          loop_edges << e
          remaining.delete(e)
          progress = true
          break
        end
      end
      next unless head == tail && loop_edges.size >= 3
      begin
        made += 1 if entities.add_face(loop_edges)
      rescue StandardError
        next
      end
    end
    made
  end

  # One link cut to `keep` long, placed with its start at `x_at`.
  def self.cropped_link(parent, template_def, keep, x_at)
    tmp = parent.add_instance(template_def, IDENTITY)
    pieces = tmp.explode.select { |e| e.valid? && e.respond_to?(:bounds) }
    work = parent.add_group(pieces)
    ents = work.entities

    bb = work.bounds
    pad = 10.mm
    x = bb.min.x + keep
    blade = ents.add_group
    blade.entities.add_face(
      [[x, bb.min.y - pad, bb.min.z - pad], [x, bb.max.y + pad, bb.min.z - pad],
       [x, bb.max.y + pad, bb.max.z + pad], [x, bb.min.y - pad, bb.max.z + pad]]
        .map { |a, b, c| Geom::Point3d.new(a, b, c) })
    # hidden = false, or SketchUp warns that visible geometry merged with hidden.
    ents.intersect_with(true, IDENTITY, ents, IDENTITY, false, blade.entities.to_a)
    blade.erase! if blade.valid?

    # Judge by CENTRE: an edge lying exactly in the cut plane must survive, or
    # there is no loop left to cap and the link comes back open.
    doomed = ents.select do |e|
      e.valid? && e.respond_to?(:bounds) &&
        (e.bounds.min.x + e.bounds.max.x) / 2.0 > x + 0.0001
    end
    ents.erase_entities(doomed) unless doomed.empty?
    cap_plane(ents, x)

    if ents.grep(Sketchup::Face).empty?
      work.erase! if work.valid?
      return nil
    end
    work.transform!(Geom::Transformation.new(
                      Geom::Vector3d.new(x_at - work.bounds.min.x, 0, 0)))
    work
  end

  def self.set_length(instance, length_mm)
    model = Sketchup.active_model
    spec = analyse(instance.definition)
    unless spec
      UI.messagebox("Not a segmented rail:\nno repeating link found.")
      return false
    end

    target = length_mm.to_f.mm
    pitch = spec[:pitch]
    if target < pitch
      UI.messagebox("Minimum length is one link (#{pitch.to_mm.round(1)} mm).")
      return false
    end

    count = (target / pitch).floor.to_i
    remainder = target - count * pitch
    if remainder < TOL.mm
      remainder = 0.0
    elsif remainder > spec[:link_w] - TOL.mm
      # Rounds up to a whole link rather than leaving a near-full crop.
      count += 1
      remainder = 0.0
    end

    model.start_operation('Set rail length', true)
    begin
      instance.make_unique
      defn = instance.definition
      template_def = model.definitions[spec[:template_name]]
      raise 'link definition not found after make_unique' unless template_def

      # Clear everything and rebuild: simpler and safer than editing in place.
      defn.entities.clear!

      origin = spec[:origin]
      count.times do |i|
        defn.entities.add_instance(
          template_def,
          Geom::Transformation.new(Geom::Point3d.new(origin + i * pitch, 0, 0)))
      end
      cropped_link(defn.entities, template_def, remainder,
                   origin + count * pitch) if remainder > 0

      # End caps: first stays at the origin, last moves to the new end.
      spec[:caps].each_with_index do |cap, i|
        next unless cap[:name]
        cap_def = model.definitions[cap[:name]]
        next unless cap_def
        at = i.zero? ? origin : origin + target
        defn.entities.add_instance(
          cap_def, Geom::Transformation.new(Geom::Point3d.new(at, 0, 0)))
      end

      model.commit_operation
    rescue StandardError => e
      model.abort_operation
      UI.messagebox("Rail resize failed:\n#{e.message}")
      return false
    end

    Sketchup.status_text =
      "Rail: #{count} x #{pitch.to_mm.round(2)} mm" \
      "#{remainder > 0 ? " + #{remainder.to_mm.round(1)} mm cropped" : ''} " \
      "= #{target.to_mm.round(1)} mm"
    true
  end

  def self.selected_rail
    sel = Sketchup.active_model.selection
    sel.grep(Sketchup::ComponentInstance).first
  rescue StandardError
    nil
  end

  def self.prompt
    inst = selected_rail
    unless inst
      UI.messagebox('Select the rail component first.')
      return
    end
    answer = UI.inputbox(['Length (mm)'], [inst.bounds.width.to_mm.round(1).to_s],
                         'Rail length')
    return unless answer
    value = answer[0].to_f
    set_length(inst, value) if value > 0
  rescue StandardError => e
    UI.messagebox("Rail length: #{e.message}")
  end

  unless defined?(@ui_loaded)
    # Deliberately cheap: no geometry inspection while building the menu. The
    # earlier version measured bounds on every right-click, which is a good way
    # to touch a stale entity at exactly the wrong moment.
    UI.add_context_menu_handler do |menu|
      begin
        menu.add_item('Set rail length...') { prompt } if selected_rail
      rescue StandardError
        nil
      end
    end
    UI.menu('Extensions').add_submenu('Rail').add_item('Set length...') { prompt }
    @ui_loaded = true
  end
end
