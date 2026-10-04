# stp2skp batch builder.
#
# Inert by default: on startup it looks for a job file written by the
# `stp2skp` CLI and does nothing at all unless one is there. SketchUp is the
# only thing that can write .skp, so this is how the pipeline finishes.
#
# Geometry is built directly from a mesh JSON rather than handed to
# Model#import: the Collada importer returns true and populates the model
# asynchronously, so saving right after it produced empty files.

require 'sketchup.rb'
require 'json'

module STP2SKP
  JOB  = File.join(Dir.home, '.local', 'share', 'stp2skp', 'job.json')
  DONE = File.join(Dir.home, '.local', 'share', 'stp2skp', 'job.done')
  LOG  = File.join(Dir.home, '.local', 'share', 'stp2skp', 'job.log')

  # Build with no automatic smoothing at all. AUTO_SOFTEN picks its own
  # threshold and softens real feature edges along with the tessellation
  # seams, which turns the whole shell into one unsnappable surface.
  # Softening is applied afterwards, per edge, by measured dihedral angle.
  NO_SMOOTH = 0

  def self.log(msg)
    File.open(LOG, 'a') { |f| f.puts("#{Time.now.strftime('%H:%M:%S')} #{msg}") }
  rescue StandardError
    nil
  end

  # Tessellation splits every flat region into triangles. Erasing the edges
  # between coplanar neighbours merges them back into single faces - fewer
  # entities, smaller file, and a model that is nicer to edit by hand.
  def self.merge_coplanar(entities)
    junk = entities.grep(Sketchup::Edge).select do |edge|
      faces = edge.faces
      faces.size == 2 && faces[0].normal.samedirection?(faces[1].normal)
    end
    entities.erase_entities(junk) unless junk.empty?
  end

  # Soften only the seams that are genuinely part of a curved surface.
  # Anything sharper than the threshold stays a hard, visible, snappable
  # edge - which is what you need for inference and dimensioning.
  def self.soften(entities, max_degrees)
    limit = max_degrees * Math::PI / 180.0
    entities.grep(Sketchup::Edge).each do |edge|
      faces = edge.faces
      next unless faces.size == 2
      curved = faces[0].normal.angle_between(faces[1].normal) < limit
      edge.soft = curved
      edge.smooth = curved
      edge.hidden = false
    end
  end

  # Attach Sketchup::Snap entities at the bore openings, so parts mate with
  # SketchUp's component snapping instead of being eyeballed into place.
  # Snaps live inside a component DEFINITION, so the part becomes a component
  # rather than a group - which also lets identical parts share geometry.
  #
  # add_snap(position, direction) - position in definition space, direction
  # pointing out of the solid. Verified against the 2025 API (25.0.659).
  def self.add_snaps(instance, snaps)
    return if snaps.nil? || snaps.empty?
    inverse = instance.transformation.inverse
    entities = instance.definition.entities
    snaps.each do |snap|
      p, d = snap['p'], snap['d']
      position = inverse * Geom::Point3d.new(p[0].mm, p[1].mm, p[2].mm)
      direction = inverse * Geom::Vector3d.new(d[0], d[1], d[2])
      begin
        entities.add_snap(position, direction)
        entities.add_cpoint(position) if @guides
      rescue StandardError => e
        log("  snap at #{p.inspect} rejected: #{e.message}")
      end
    end
  end

  # Catalogue data onto the component definition: description shows in the
  # Components browser and in tooltips, attributes are queryable by report
  # extensions and by any Ruby that walks the model.
  def self.apply_metadata(definition, meta)
    return if meta.empty?
    meta.each { |k, v| definition.set_attribute('stp2skp', k.to_s, v.to_s) }
    summary = [meta['code'], meta['size_code']].compact.reject(&:empty?).join(' ')
    parts = [summary, meta['name'], meta['designation']].compact
    text = parts.reject { |x| x.to_s.empty? }.join(' - ')
    definition.description = text unless text.empty?
  end

  def self.build(model, path)
    data = JSON.parse(File.read(path))
    meta = data['meta'] || {}
    faces = 0
    @snaps_added = 0

    # Model-level: survives even if the component is exploded.
    meta.each { |k, v| model.set_attribute('stp2skp', k.to_s, v.to_s) }

    model.start_operation('stp2skp build', true)
    data['parts'].each do |part|
      v, f = part['v'], part['f']
      mesh = Geom::PolygonMesh.new(v.size / 3, f.size / 3)

      # add_point merges coincident points and returns the real index, so map
      # source index -> mesh index rather than assuming they line up.
      idx = []
      i = 0
      while i < v.size
        idx << mesh.add_point(Geom::Point3d.new(v[i].mm, v[i + 1].mm, v[i + 2].mm))
        i += 3
      end

      i = 0
      while i < f.size
        mesh.add_polygon(idx[f[i]], idx[f[i + 1]], idx[f[i + 2]])
        i += 3
      end

      group = model.entities.add_group
      group.entities.add_faces_from_mesh(mesh, NO_SMOOTH)
      merge_coplanar(group.entities) if @merge
      soften(group.entities, @smooth_angle)
      faces += group.entities.grep(Sketchup::Face).size

      instance = group.to_component
      name = part['name'].to_s
      unless name.empty?
        instance.definition.name = model.definitions.unique_name(name)
        instance.name = name
      end
      apply_metadata(instance.definition, meta)
      add_snaps(instance, part['snaps'])
      @snaps_added += (part['snaps'] || []).size
    end
    model.commit_operation

    faces
  end

  # Place an isometric camera framing the model, derived purely from its
  # bounding box so it does not depend on a drawn viewport.
  def self.frame(model)
    bb = model.bounds
    center = bb.center
    dist = [bb.diagonal, 1.mm].max * 1.6
    eye = center + Geom::Vector3d.new(dist * 0.55, -dist * 0.75, dist * 0.45)
    model.active_view.camera = Sketchup::Camera.new(eye, center, Z_AXIS)
    # The computed camera sets the viewing angle; zoom_extents does the actual
    # fitting. Verified: without this the file opens needing Shift+Z.
    model.active_view.zoom_extents
  rescue StandardError => e
    log("  camera framing failed: #{e.message}")
  end

  # SketchUp may still be booting when plugins load, so poll for a usable
  # model rather than assuming one exists.
  def self.arm
    return unless File.exist?(JOB)
    log('plugin loaded, waiting for a model')
    # Jobs that drive Dynamic Components must also wait for the DC extension
    # to finish loading - our timer can fire before $dc_observers exists.
    needs_dc = begin
      JSON.parse(File.read(JOB))['mode'] == 'variants'
    rescue StandardError
      false
    end
    @tries = 0
    @timer = UI.start_timer(1.0, true) do
      @tries += 1
      if needs_dc && !(defined?($dc_observers) && $dc_observers) && @tries <= 30
        log('  waiting for the DC engine...') if @tries % 10 == 1
      elsif Sketchup.active_model
        UI.stop_timer(@timer)
        run
      elsif @tries > 60
        UI.stop_timer(@timer)
        log('gave up: no active model after 60s')
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => 'no model' }))
      end
    end
  end

  # Lay every component out on one sheet: rows are part codes, columns are
  # nominal sizes. Column widths and row depths come from the actual bounding
  # boxes, so nothing overlaps regardless of how the parts are modelled.
  def self.build_sheet(job)
    model = Sketchup.active_model
    model.entities.clear!
    model.definitions.purge_unused

    gap = (job['gap'] || 20).to_f.mm

    # Pass 1: instantiate at the origin and measure what we actually placed.
    cells = {}
    job['cells'].each do |cell|
      wrapper = model.definitions.load(cell['path'])
      definition, transform = unwrap(wrapper)
      instance = model.entities.add_instance(definition, transform)
      key = [cell['row'], cell['col']]
      (cells[key] ||= []) << [instance, cell['label']]
    end

    # Pipes are generated in place rather than imported, so the catalogue row
    # carries the real definitions - snaps, metadata and DC attributes - and
    # not a flattened copy of them.
    (job['pipes'] || []).each do |spec|
      definition = build_pipe(model, spec)
      instance = model.entities.add_instance(definition, Geom::Transformation.new)
      key = [spec['row'], spec['col']]
      (cells[key] ||= []) << [instance, spec['label']]
    end

    cell_w = Hash.new(0.0)
    cell_d = Hash.new(0.0)
    cells.each do |key, list|
      cell_w[key] = list.map { |i, _| i.bounds.width }.sum + gap * [list.size - 1, 0].max
      cell_d[key] = list.map { |i, _| i.bounds.height }.max
    end
    rows = cells.keys.map(&:first).uniq.sort
    cols = cells.keys.map(&:last).uniq.sort
    col_w = cols.map { |c| [rows.map { |r| cell_w[[r, c]] }.max, 1.mm].max }
    row_d = rows.map { |r| [cols.map { |c| cell_d[[r, c]] }.max, 1.mm].max }

    col_x = {}
    x = 0.0
    cols.each_with_index { |c, i| col_x[c] = x; x += col_w[i] + gap * 3 }
    row_y = {}
    y = 0.0
    rows.reverse.each_with_index { |r, i| row_y[r] = y; y += row_d[rows.size - 1 - i] + gap * 3 }

    # Pass 2: move each instance into its cell.
    placed = 0
    cells.each do |(r, c), list|
      offset = 0.0
      list.sort_by { |_, label| label.to_s }.each do |instance, label|
        bounds = instance.bounds
        instance.transform!(Geom::Transformation.new(
          Geom::Vector3d.new(col_x[c] + offset - bounds.min.x,
                             row_y[r] - bounds.min.y,
                             -bounds.min.z)))
        text(model.entities, label.to_s,
             col_x[c] + offset, row_y[r] - gap * 1.5, gap * 0.45)
        offset += bounds.width + gap
        placed += 1
      end
    end

    # Drop the loaded wrappers, which now have no instances.
    model.definitions.purge_unused

    job['rows'].each do |row|
      text(model.entities, row['label'], -gap * 2, row_y[row['index']], gap, :right)
    end
    job['cols'].each do |col|
      text(model.entities, col['label'], col_x[col['index']], y + gap, gap * 1.4)
    end

    placed
  end

  # definitions.load wraps a whole .skp in an outer definition named after the
  # file's scene ("Plan View#110"), burying the real component - and its
  # metadata - one level down. If the wrapper holds nothing but a single
  # instance, use that instance's definition directly.
  def self.unwrap(definition)
    contents = definition.entities.to_a
    instances = contents.grep(Sketchup::ComponentInstance)
    return [definition, Geom::Transformation.new] unless
      instances.size == 1 && contents.size == 1
    [instances[0].definition, instances[0].transformation]
  end

  def self.text(entities, string, x, y, height, align = :left)
    group = entities.add_group
    ok = group.entities.add_3d_text(string, TextAlignLeft, 'Arial',
                                    false, false, height, 0.0, 0.0, true, 0.0)
    return nil unless ok
    dx = align == :right ? -group.bounds.width : 0.0
    group.transform!(Geom::Transformation.new(Geom::Point3d.new(x + dx, y, 0)))
    group
  rescue StandardError => e
    log("  label '#{string}' failed: #{e.message}")
    nil
  end

  # Build a parametric pipe: an annular tube along the red axis, scalable in
  # length only. A cylinder scales exactly along its own axis, so stretching
  # is geometrically correct - no distortion of the cross-section.
  def self.build_pipe(model, spec)
    dn = spec['dn'].to_f
    wall = spec['wall'].to_f
    length = spec['length'].to_f
    segments = (spec['segments'] || 24).to_i

    definition = model.definitions.add(spec['name'])
    entities = definition.entities
    outer = (dn / 2.0).mm
    inner = (dn / 2.0 - wall).mm

    # Disc first, then the bore circle splits it. Doing it in this order is
    # what actually produces two faces.
    outer_edges = entities.add_circle(ORIGIN, X_AXIS, outer, segments)
    entities.add_face(outer_edges)
    entities.add_circle(ORIGIN, X_AXIS, inner, segments)

    # Identify by the radius of each face's OUTER loop: the annulus reaches
    # the pipe's outside, the bore disc only reaches the inner wall. Area is
    # misleading (a thin annulus is smaller than its bore) and loop counts
    # vary with how SketchUp splits the disc.
    faces = entities.grep(Sketchup::Face)
    radius_of = lambda do |f|
      f.outer_loop.vertices.map { |v| v.position.distance(ORIGIN) }.max
    end
    log("  DN#{dn.round}: #{faces.size} face(s), outer-loop radii " +
        faces.map { |f| radius_of.call(f).to_mm.round(2) }.inspect)
    ring = faces.max_by { |f| radius_of.call(f) }
    raise 'could not form pipe annulus' if ring.nil?
    (faces - [ring]).each { |f| f.erase! if f.valid? }

    distance = length.mm
    distance = -distance if ring.normal.x < 0
    ring.pushpull(distance)

    # A shell has both walls plus two ring caps; a solid rod would have far
    # fewer faces and a radius of the bore rather than the outside.
    shell_faces = entities.grep(Sketchup::Face).size
    box = definition.bounds
    log("  DN#{dn.round}: #{shell_faces} faces, " \
        "#{box.width.to_mm.round(1)}x#{box.height.to_mm.round(1)}x" \
        "#{box.depth.to_mm.round(1)}mm")
    raise "pipe DN#{dn.round} is not a shell (#{shell_faces} faces)" if
      shell_faces < segments * 2

    soften(entities, 25)

    # Snaps on the axis at both ends, facing out, matching the fittings.
    [[0.0, -1.0], [length, 1.0]].each do |along, direction|
      begin
        entities.add_snap(Geom::Point3d.new(along.mm, 0, 0),
                          Geom::Vector3d.new(direction, 0, 0))
        entities.add_cpoint(Geom::Point3d.new(along.mm, 0, 0))
      rescue StandardError => e
        log("  pipe snap failed: #{e.message}")
      end
    end

    # Length-only scaling: disable every handle except along red.
    # 2=Y 4=Z 8=XY 16=XZ 32=YZ 64=uniform
    definition.behavior.no_scale_mask = 2 + 4 + 8 + 16 + 32 + 64

    meta = {
      'code' => spec['code'], 'name' => spec['label'], 'dn' => dn.round,
      'od_mm' => dn, 'wall_mm' => wall, 'material' => 'stainless steel',
      'vendor' => 'Valtec', 'group' => 'Труба из нержавеющей стали'
    }
    apply_metadata(definition, meta)

    # Dynamic Component attributes so the length can be typed into
    # Component Options rather than dragged.
    dict = 'dynamic_attributes'
    definition.set_attribute(dict, '_name', spec['name'])
    definition.set_attribute(dict, '_lengthunits', 'MILLIMETERS')
    definition.set_attribute(dict, 'lenx', length.mm.to_f)
    definition.set_attribute(dict, '_lenx_label', 'Length')
    definition.set_attribute(dict, '_lenx_formlabel', 'Length')
    definition.set_attribute(dict, '_lenx_units', 'MILLIMETERS')
    definition.set_attribute(dict, '_lenx_access', 'TEXTBOX')
    definition.set_attribute(dict, '_lenx_nextvalue', '')
    definition.set_attribute(dict, 'dn', dn.round)
    definition.set_attribute(dict, '_dn_label', 'DN')
    definition.set_attribute(dict, '_dn_access', 'VIEW')
    definition.set_attribute(dict, '_dn_units', 'STRING')
    definition
  end

  # ---- traced profiles ------------------------------------------------------

  # Extrude a traced side profile across the part's width, then cut features.
  # The profile comes from the drawing itself, so the silhouette matches what
  # was drawn rather than an idealised reconstruction of it.
  def self.build_profile(model, spec)
    width = spec['width'].to_f.mm
    points = spec['poly'].map { |x, z| Geom::Point3d.new(x.to_f.mm, 0, z.to_f.mm) }

    group = model.entities.add_group
    face = group.entities.add_face(points)
    raise "profile #{spec['name']} did not close" if face.nil?
    face.pushpull(face.normal.y > 0 ? -width : width)
    # Normalise to y in [0, width]: the profile face's normal direction is not
    # predictable, and every cutter below is positioned for that range. Getting
    # this wrong makes cuts miss the part while still reporting success.
    dy = -group.bounds.min.y
    group.transform!(Geom::Transformation.new(Geom::Vector3d.new(0, dy, 0))) if dy.abs > 0.001
    log("  #{spec['name']}: #{spec['poly'].size} pts, " \
        "y #{group.bounds.min.y.to_mm.round(1)}..#{group.bounds.max.y.to_mm.round(1)}mm, " \
        "#{group.manifold? ? 'manifold' : 'NOT MANIFOLD'}")

    (spec['slots'] || []).each do |slot|
      top = spec['top_z'].to_f.mm + 2.mm
      cutter = slot_cutter(model, slot['x'].to_f.mm, width / 2, top,
                           slot['len'].to_f.mm, slot['wide'].to_f.mm,
                           spec['top_z'].to_f.mm + 4.mm)
      group = cut(group, cutter)
    end

    # Cutouts traced off the drawing, punched through the full width.
    (spec['cuts'] || []).each do |c|
      cutter = model.entities.add_group
      pts = c['poly'].map { |x, z| Geom::Point3d.new(x.to_f.mm, -1.mm, z.to_f.mm) }
      f = cutter.entities.add_face(pts)
      if f.nil?
        log("  cutout '#{c['name']}' did not close")
        cutter.erase!
        next
      end
      f.pushpull(f.normal.y > 0 ? -(width + 2.mm) : (width + 2.mm))
      dy = -1.mm - cutter.bounds.min.y
      cutter.transform!(Geom::Transformation.new(Geom::Vector3d.new(0, dy, 0))) if dy.abs > 0.001
      unless cutter.manifold?
        log("  cutout '#{c['name']}' is NOT MANIFOLD - skipped")
        cutter.erase!
        next
      end
      group = cut(group, cutter)
    end

    # The gap between the hinged band and the pipe seat: a long thin traced
    # sliver never extrudes into a valid solid, so rebuild it as the annular
    # sector it actually is (measured r 15.8-18.2mm, -13 to 82 degrees).
    if spec['arc_cut']
      a = spec['arc_cut']
      cutter = model.entities.add_group
      segs = 40
      pts = []
      (0..segs).each do |i|
        t = (a['a0'] + (a['a1'] - a['a0']) * i.to_f / segs) * Math::PI / 180.0
        pts << Geom::Point3d.new(a['cx'].to_f.mm + a['r1'].to_f.mm * Math.cos(t), -1.mm,
                                 a['cz'].to_f.mm + a['r1'].to_f.mm * Math.sin(t))
      end
      (0..segs).each do |i|
        t = (a['a1'] + (a['a0'] - a['a1']) * i.to_f / segs) * Math::PI / 180.0
        pts << Geom::Point3d.new(a['cx'].to_f.mm + a['r0'].to_f.mm * Math.cos(t), -1.mm,
                                 a['cz'].to_f.mm + a['r0'].to_f.mm * Math.sin(t))
      end
      f = cutter.entities.add_face(pts)
      if f.nil?
        log('  arc cut did not close')
        cutter.erase!
      else
        f.pushpull(f.normal.y > 0 ? -(width + 2.mm) : (width + 2.mm))
        dy = -1.mm - cutter.bounds.min.y
        cutter.transform!(Geom::Transformation.new(Geom::Vector3d.new(0, dy, 0))) if dy.abs > 0.001
        if cutter.manifold?
          group = cut(group, cutter)
        else
          log('  arc cutter NOT MANIFOLD')
          cutter.erase!
        end
      end
    end

    if spec['bolt']
      b = spec['bolt']
      # Remove the screw as drawn - the silhouette renders it as a flat slab -
      # then rebuild it as a round bolt.
      notch = model.entities.add_group
      # Explicit notch bounds when given: the notch must OVERLAP the seat, or
      # a hair-thin wall survives between the two voids beside the screw.
      x0 = (b['notch_x0'] || (b['x'].to_f - b['shaft_d'].to_f / 2 - 0.4)).to_f.mm
      x1 = (b['notch_x1'] || (b['x'].to_f + b['shaft_d'].to_f / 2 + 0.4)).to_f.mm
      z0, z1 = b['z0'].to_f.mm, b['z1'].to_f.mm
      nf = notch.entities.add_face([[x0, -1.mm, z0], [x1, -1.mm, z0],
                                    [x1, -1.mm, z1], [x0, -1.mm, z1]]
                                   .map { |x, y, z| Geom::Point3d.new(x, y, z) })
      nf.pushpull(nf.normal.y > 0 ? -(width + 2.mm) : (width + 2.mm))
      dy = -1.mm - notch.bounds.min.y
      notch.transform!(Geom::Transformation.new(Geom::Vector3d.new(0, dy, 0))) if dy.abs > 0.001
      group = cut(group, notch)

      shaft = tube(model, Geom::Point3d.new(b['x'].to_f.mm, width / 2, b['z0'].to_f.mm),
                   Z_AXIS, b['shaft_d'].to_f.mm / 2, 0, b['z1'].to_f.mm - b['z0'].to_f.mm, 16)
      head = tube(model, Geom::Point3d.new(b['x'].to_f.mm, width / 2, b['z1'].to_f.mm),
                  Z_AXIS, b['head_d'].to_f.mm / 2, 0, b['head_h'].to_f.mm, 16)
      merged = shaft.respond_to?(:union) ? shaft.union(head) : nil
      bolt = merged || shaft
      joined = group.respond_to?(:union) ? bolt.union(group) : nil
      if joined
        group = joined
        log('  bolt added')
      else
        log('  bolt union failed, left as separate solid')
      end
    end

    if spec['bore']
      bore = spec['bore']
      cutter = tube(model, Geom::Point3d.new(bore['x'].to_f.mm, -1.mm, bore['z'].to_f.mm),
                    Y_AXIS, bore['r'].to_f.mm, 0, width + 2.mm, 48)
      group = cut(group, cutter)
    end

    # Traced outlines have many small-angle vertices; a CAD-style 22 degree
    # threshold softens nearly every edge and hides the part's real corners.
    soften(group.entities, (spec['smooth'] || 10).to_f)
    # Volume is the honest test: a flat, un-extruded face reports nothing.
    volume = group.respond_to?(:volume) ? group.volume : -1
    instance = group.to_component
    definition = instance.definition
    definition.name = model.definitions.unique_name(spec['name'])
    apply_metadata(definition, spec['meta'] || {})
    b = definition.bounds
    log("  #{spec['name']}: #{definition.entities.grep(Sketchup::Face).size} faces, " \
        "volume #{volume > 0 ? (volume / 1000.0.mm / 1.mm / 1.mm).round : 'NONE'} cm3, " \
        "#{b.width.to_mm.round}x#{b.depth.to_mm.round}x#{b.height.to_mm.round}mm")
    # to_component may re-base the definition's origin and compensate with the
    # instance transform. Keep that transform: it is what maps definition
    # coordinates back to the coordinates the part was BUILT in, so every
    # later placement must be composed with it.
    [instance, definition, instance.transformation]
  end

  def self.build_profiles(job)
    model = Sketchup.active_model
    model.entities.clear!
    model.definitions.purge_unused

    support_inst, support_def, support_tr = build_profile(model, job['support'])
    support_def.save_as(File.join(job['dir'], job['support']['name'] + '.skp'))
    support_inst.erase!

    y = 0.0
    written = 1
    job['brackets'].each do |spec|
      inst, defn, defn_tr = build_profile(model, spec)
      inst.erase!
      defn.save_as(File.join(job['dir'], spec['name'] + '.skp'))
      written += 1

      width = job['support']['width'].to_f.mm
      placed = model.entities.add_instance(support_def,
        Geom::Transformation.new(Geom::Point3d.new(0, y, 0)) * support_tr)
      sb = placed.bounds
      log("    support at x #{sb.min.x.to_mm.round(1)}..#{sb.max.x.to_mm.round(1)}, " \
          "z #{sb.min.z.to_mm.round(1)}..#{sb.max.z.to_mm.round(1)}mm")
      spec['places'].each do |place|
        # Each clamp sits on its own platform, not on the baseline.
        put = model.entities.add_instance(defn,
          Geom::Transformation.new(
            Geom::Point3d.new(place['x'].to_f.mm, y + place['y'].to_f.mm,
                              place['z'].to_f.mm)) * defn_tr)
        pb = put.bounds
        log("    clamp at x #{place['x']} -> base z #{pb.min.z.to_mm.round(1)}mm " \
            "(platform #{place['z']}), y #{(pb.min.y - y).to_mm.round(1)}.." \
            "#{(pb.max.y - y).to_mm.round(1)}mm")
      end
      text(model.entities, spec['label'], -70.mm, y, 10.mm)
      y += width + 60.mm
    end

    frame(model)
    model.save(job['out'])
    written
  end

  # ---- 7480 bracket family -------------------------------------------------

  # A tube as its own group, used for the clamp ring and for hole cutters.
  def self.tube(model, center, axis, r_out, r_in, length, segments = 24)
    group = model.entities.add_group
    entities = group.entities
    outer = entities.add_circle(center, axis, r_out, segments)
    entities.add_face(outer)
    entities.add_circle(center, axis, r_in, segments) if r_in > 0

    faces = entities.grep(Sketchup::Face)
    radius_of = lambda { |f| f.outer_loop.vertices.map { |v| v.position.distance(center) }.max }
    ring = faces.max_by { |f| radius_of.call(f) }
    (faces - [ring]).each { |f| f.erase! if f.valid? }

    distance = length
    distance = -distance if ring.normal.dot(axis) < 0
    ring.pushpull(distance)
    soften(entities, 25)
    group
  end

  # Stadium-shaped cutter for the adjustment slots.
  def self.slot_cutter(model, cx, cy, z0, len, wide, depth)
    group = model.entities.add_group
    entities = group.entities
    r = wide / 2.0
    dx = len / 2.0 - r
    # End caps must bulge along X. Sweeping from -Y about -Z carries the left
    # cap through -X, and from +Y about -Z carries the right cap through +X;
    # getting these axes wrong yields two -Y bulges and an unclosed loop.
    entities.add_arc(Geom::Point3d.new(cx - dx, cy, z0),
                     Y_AXIS.reverse, Z_AXIS.reverse, r, 0, Math::PI, 12)
    entities.add_arc(Geom::Point3d.new(cx + dx, cy, z0),
                     Y_AXIS, Z_AXIS.reverse, r, 0, Math::PI, 12)
    entities.add_line([cx - dx, cy - r, z0], [cx + dx, cy - r, z0])
    entities.add_line([cx - dx, cy + r, z0], [cx + dx, cy + r, z0])
    face = entities.add_face(entities.grep(Sketchup::Edge))
    if face.nil?
      log('  slot face did not close')
      return group
    end
    face.pushpull(face.normal.z > 0 ? -depth : depth)
    log("  slot cutter: #{group.manifold? ? 'manifold' : 'NOT MANIFOLD'}")
    group
  end

  # Solid Tools are Pro-only and can return nil when an operation fails, so
  # never assume the cut happened - fall back to the uncut solid.
  def self.cut(target, tool)
    unless target.respond_to?(:subtract)
      tool.erase!
      log('  no Solid Tools: holes skipped')
      return target
    end
    # a.subtract(b) removes A FROM B and returns B-minus-A, so the CUTTER is
    # the receiver. Calling it the other way round returns the cutter shape
    # with the part carved out of it - a bare cylinder instead of a clamp.
    before = target.bounds
    before_volume = target.respond_to?(:volume) ? target.volume : 0
    result = tool.subtract(target)
    if result.nil?
      log('  subtract failed, leaving material')
      return target
    end
    after = result.bounds
    if after.width < before.width * 0.5 || after.depth < before.depth * 0.5
      log("  CUT LOOKS INVERTED: #{before.width.to_mm.round}x#{before.depth.to_mm.round}" \
          " -> #{after.width.to_mm.round}x#{after.depth.to_mm.round}mm")
    else
      removed = before_volume - (result.respond_to?(:volume) ? result.volume : 0)
      if before_volume > 0 && removed <= before_volume * 0.0005
        log('  CUT REMOVED NOTHING - cutter missed the part')
      else
        log("  cut ok (removed #{(removed / 1.mm / 1.mm / 1.mm).round} mm3)")
      end
    end
    result
  end

  def self.build_support(model, spec)
    f = spec['f'].to_f.mm
    g = spec['g'].to_f.mm
    t = spec['thickness'].to_f.mm
    step = spec['step'].to_f.mm
    x1 = spec['ramp_start'].to_f.mm
    x2 = spec['ramp_end'].to_f.mm

    # Side profile in XZ, extruded across the strap width.
    profile = [[0, 0, 0], [x1, 0, 0], [x2, 0, step], [f, 0, step],
               [f, 0, step + t], [x2, 0, step + t], [x1, 0, t], [0, 0, t]]
    group = model.entities.add_group
    face = group.entities.add_face(profile.map { |x, y, z| Geom::Point3d.new(x, y, z) })
    face.pushpull(face.normal.y > 0 ? -g : g)

    log("  support solid: #{group.manifold? ? 'manifold' : 'NOT MANIFOLD'}")

    spec['slots'].each do |slot|
      cutter = slot_cutter(model, slot['x'].to_f.mm, g / 2, step + t + 1.mm,
                           slot['len'].to_f.mm, slot['wide'].to_f.mm, step + t + 2.mm)
      group = cut(group, cutter)
    end
    spec['holes'].each do |hole|
      z = hole['z'].to_f.mm
      cutter = tube(model, Geom::Point3d.new(hole['x'].to_f.mm, g / 2, z + t + 1.mm),
                    Z_AXIS, hole['d'].to_f.mm / 2, 0, -(t + 2.mm))
      group = cut(group, cutter)
    end

    instance = group.to_component
    definition = instance.definition
    definition.name = model.definitions.unique_name(spec['name'])
    apply_metadata(definition, spec['meta'])
    [instance, definition]
  end

  def self.build_bracket(model, spec)
    od = spec['pipe_od'].to_f.mm
    a = spec['a'].to_f.mm
    wall = spec['ring_wall'].to_f.mm
    band = spec['band_width'].to_f.mm
    strap = spec['strap'].to_f.mm

    r_in = od / 2
    r_out = r_in + wall
    parts = []

    # Ring around the pipe, axis along the strap width.
    parts << tube(model, Geom::Point3d.new(0, -band / 2, a), Y_AXIS, r_out, r_in, band)

    # Pedestal from the plate up to the underside of the ring.
    pedestal_h = a - r_out
    if pedestal_h > 0
      ped = model.entities.add_group
      w = [r_out, 10.mm].max
      pface = ped.entities.add_face(
        [[-w, -band / 2, 0], [w, -band / 2, 0], [w, band / 2, 0], [-w, band / 2, 0]]
          .map { |x, y, z| Geom::Point3d.new(x, y, z) })
      pface.pushpull(pface.normal.z > 0 ? pedestal_h : -pedestal_h)
      parts << ped
    end

    # Closing strap over the top, and the clamping screw beside it.
    cap = model.entities.add_group
    cface = cap.entities.add_face(
      [[-r_out, -band / 2, a + r_in], [r_out, -band / 2, a + r_in],
       [r_out, band / 2, a + r_in], [-r_out, band / 2, a + r_in]]
        .map { |x, y, z| Geom::Point3d.new(x, y, z) })
    cface.pushpull(cface.normal.z > 0 ? strap : -strap)
    parts << cap
    parts << tube(model, Geom::Point3d.new(-r_out + 2.mm, 0, a + r_in + strap),
                  Z_AXIS, 2.5.mm, 0, 10.mm, 12)

    group = parts.shift
    parts.each do |piece|
      merged = group.respond_to?(:union) ? group.union(piece) : nil
      group = merged || group
    end

    instance = group.to_component
    definition = instance.definition
    definition.name = model.definitions.unique_name(spec['name'])
    apply_metadata(definition, spec['meta'])

    # Snaps: pipe axis at both faces of the band, and the mounting foot.
    entities = definition.entities
    [[-band / 2, -1.0], [band / 2, 1.0]].each do |y, dir|
      begin
        entities.add_snap(Geom::Point3d.new(0, y, a), Geom::Vector3d.new(0, dir, 0))
        entities.add_cpoint(Geom::Point3d.new(0, y, a))
      rescue StandardError => e
        log("  bracket snap failed: #{e.message}")
      end
    end
    begin
      entities.add_snap(ORIGIN, Geom::Vector3d.new(0, 0, -1))
    rescue StandardError => e
      log("  bracket foot snap failed: #{e.message}")
    end

    [instance, definition]
  end

  def self.build_brackets(job)
    model = Sketchup.active_model
    model.entities.clear!
    model.definitions.purge_unused

    support_instance, support_def = build_support(model, job['support'])
    support_def.save_as(File.join(job['dir'], job['support']['name'] + '.skp'))
    support_instance.erase!

    y = 0.0
    written = 1
    job['articles'].each do |article|
      _instance, bracket_def = build_bracket(model, article)
      model.entities.grep(Sketchup::ComponentInstance).each { |i| i.erase! if i.definition == bracket_def }
      bracket_def.save_as(File.join(job['dir'], article['name'] + '.skp'))
      written += 1

      # Lay out an assembled example: strap plus two clamps at spacing C.
      t = job['support']['thickness'].to_f.mm
      step = job['support']['step'].to_f.mm
      g = job['support']['g'].to_f.mm
      centre = job['support']['f'].to_f.mm / 2
      half = article['c'].to_f.mm / 2
      placed = model.entities.add_instance(support_def,
        Geom::Transformation.new(Geom::Point3d.new(0, y, 0)) * support_tr)
      sb = placed.bounds
      log("    support at x #{sb.min.x.to_mm.round(1)}..#{sb.max.x.to_mm.round(1)}, " \
          "z #{sb.min.z.to_mm.round(1)}..#{sb.max.z.to_mm.round(1)}mm")
      model.entities.add_instance(bracket_def,
        Geom::Transformation.new(Geom::Point3d.new(centre - half, y + g / 2, t)))
      model.entities.add_instance(bracket_def,
        Geom::Transformation.new(Geom::Point3d.new(centre + half, y + g / 2, step + t)))
      text(model.entities, article['label'], -60.mm, y, 12.mm)
      y += 120.mm
    end

    frame(model)
    model.save(job['out'])
    written
  end

  def self.build_pipes(job)
    model = Sketchup.active_model
    model.entities.clear!
    model.definitions.purge_unused

    gap = (job['gap'] || 40).to_f.mm
    y = 0.0
    built = []
    job['pipes'].each do |spec|
      definition = build_pipe(model, spec)
      model.entities.add_instance(
        definition, Geom::Transformation.new(Geom::Point3d.new(0, y, 0)))
      text(model.entities, spec['label'], -gap * 4, y, gap * 0.6)
      y += (spec['dn'].to_f.mm + gap)
      if job['dir']
        path = File.join(job['dir'], spec['name'] + '.skp')
        definition.save_as(path)
        built << path
      end
    end

    frame(model)
    model.save(job['out'])
    # Behavior#no_scale_mask is write-only, so there is nothing to read back.
    log("dc engine: #{defined?($dc_observers) ? 'loaded' : 'MISSING'}")
    built.size
  end

  # ---- bill of materials ----------------------------------------------------

  # Walk the model counting component instances. Nested components multiply:
  # a definition used twice inside a component placed three times is six.
  # Groups are traversed but never counted - they are not BOM items.
  def self.bom_walk(entities, mult, tally, tr = Geom::Transformation.new, depth = 0)
    return if depth > 24
    entities.each do |e|
      if e.is_a?(Sketchup::ComponentInstance)
        d = e.definition
        here = tr * e.transformation
        row = (tally[d.name] ||= { 'count' => 0, 'defn' => d, 'lengths' => [] })
        row['count'] += mult

        # Pipes are one definition stretched per run, so the instance's scale
        # carries the real length - collapsing by definition alone would
        # report thirteen identical pipes instead of thirteen cut lengths.
        if d.get_attribute('stp2skp', 'od_mm')
          length = pipe_length(e, d, here)
          mult.times { row['lengths'] << length }
        end

        bom_walk(d.entities, mult, tally, here, depth + 1)
      elsif e.is_a?(Sketchup::Group)
        bom_walk(e.entities, mult, tally, tr * e.transformation, depth + 1)
      end
    end
  end

  # Length of one pipe instance, in mm.
  #
  # Transformation#xaxis is NORMALISED, so it reads 1.0 however the instance is
  # scaled - the scale has to come from the matrix columns instead. And because
  # these are Dynamic Components, the DC engine keeps the authoritative length
  # in its own lenx attribute, which is preferred when present.
  def self.matrix_xscale(tr)
    a = tr.to_a
    Math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) / (a[15].zero? ? 1.0 : a[15])
  end

  def self.pipe_length(instance, definition, tr)
    # ONLY the instance's lenx counts. The definition also carries one - the
    # unscaled length written at build time - and falling back to it reported
    # every pipe as 300mm however it had been stretched.
    lenx = instance.get_attribute('dynamic_attributes', 'lenx')
    return lenx.to_f.to_mm if lenx && lenx.to_f > 0
    definition.bounds.width.to_mm * matrix_xscale(tr)
  end

  def self.build_bom(job)
    model = Sketchup.active_model
    tally = {}
    bom_walk(model.entities, 1, tally)

    fields = %w[code name thread dn pipe_od_mm size_code designation material vendor group]

    # Merge SketchUp's duplicate-name variants. Importing the same part twice
    # makes "Pipe DN18", "Pipe DN18#3", "Pipe DN18#4" - three definitions of
    # one product. Group by catalogue identity where we have it, otherwise by
    # the name with its #n suffix stripped.
    merged = {}
    tally.each do |name, row|
      d = row['defn']
      code = d.get_attribute('stp2skp', 'code')
      size = d.get_attribute('stp2skp', 'size_code') || d.get_attribute('stp2skp', 'file')
      base = name.to_s.sub(/#\d+\z/, '')
      key = code ? [code, size, base].compact.join(' ') : base
      m = (merged[key] ||= { 'count' => 0, 'defn' => d, 'name' => base,
                             'variants' => 0, 'lengths' => [] })
      m['count'] += row['count']
      m['variants'] += 1
      m['lengths'].concat(row['lengths'] || [])
    end

    rows = merged.map do |_key, row|
      d = row['defn']
      meta = fields.map { |f| d.get_attribute('stp2skp', f) }
      bb = d.bounds
      total = row['lengths'].empty? ? '' : row['lengths'].sum.round(1)
      [row['name'], row['count'], *meta,
       "#{bb.width.to_mm.round(1)}x#{bb.depth.to_mm.round(1)}x#{bb.height.to_mm.round(1)}",
       d.description.to_s, row['variants'], total]
    end
    rows.sort_by! { |r| [-r[1], r[0].to_s] }

    header = ['part', 'qty', *fields, 'bbox_mm', 'description', 'definitions',
              'total_length_mm']
    csv = ([header] + rows).map do |r|
      r.map { |v| s = v.to_s; s =~ /[",\n]/ ? '"' + s.gsub('"', '""') + '"' : s }.join(',')
    end.join("\n")
    File.write(job['out'], csv + "\n")

    # Cut list: every stretched run, grouped by length.
    cut = [['part', 'code', 'dn', 'length_mm', 'qty', 'subtotal_mm']]
    grand = 0.0
    merged.each_value do |row|
      next if row['lengths'].empty?
      d = row['defn']
      by_len = Hash.new(0)
      row['lengths'].each { |l| by_len[l.round(0)] += 1 }
      by_len.sort_by { |l, _| -l }.each do |len, qty|
        cut << [row['name'], d.get_attribute('stp2skp', 'code'),
                d.get_attribute('stp2skp', 'dn'), len, qty, (len * qty).round(0)]
        grand += len * qty
      end
    end
    if cut.size > 1
      path = job['out'].sub(/\.csv\z/, '') + '.cutlist.csv'
      csv2 = cut.map { |r| r.map { |v| v.to_s }.join(',') }.join("\n")
      File.write(path, csv2 + "\n")
      log("cut list: #{cut.size - 1} distinct lengths, total #{(grand / 1000).round(2)} m")
      cut.drop(1).sort_by { |r| -r[3] }.first(25).each do |r|
        log(format('    %-18s %6s mm x %-3s = %7s mm', r[0].to_s[0, 18], r[3], r[4], r[5]))
      end
    end

    # Explain oversized or unnamed containers: a 20m component is a container,
    # not a part, and the BOM is misleading unless you know what is in it.
    merged.each_value do |row|
      d = row['defn']
      bb = d.bounds
      next unless bb.width.to_mm > 3000 || bb.height.to_mm > 3000 || bb.depth.to_mm > 3000
      kinds = Hash.new(0)
      d.entities.each { |x| kinds[x.class.name.split('::').last] += 1 }
      nested = d.entities.grep(Sketchup::ComponentInstance).map { |i| i.definition.name }.uniq
      log("  LARGE '#{d.name}' x#{row['count']} " \
          "#{bb.width.to_mm.round}x#{bb.depth.to_mm.round}x#{bb.height.to_mm.round}mm")
      log("    contents: #{kinds.sort_by { |_k, v| -v }.first(6).map { |k, v| "#{v} #{k}" }.join(', ')}")
      log("    nested components: #{nested.first(8).inspect}#{nested.size > 8 ? " (+#{nested.size - 8})" : ''}")
    end

    log("bom: #{rows.size} distinct parts (#{tally.size} definitions), " \
        "#{rows.sum { |r| r[1] }} instances total")
    rows.first(40).each { |r| log(format('    %-28s %4d  %s', r[0].to_s[0, 28], r[1], r[2] || '')) }
    rows.size
  end

  # ---- inspect a dynamic component -----------------------------------------

  def self.describe_dc(job)
    model = Sketchup.active_model
    out = []

    walk = lambda do |defn, path, depth|
      return if depth > 6
      dict = defn.attribute_dictionaries &&
             defn.attribute_dictionaries['dynamic_attributes']
      if dict
        attrs = {}
        dict.each_pair { |k, v| attrs[k] = v }
        # Split user-facing fields from the _underscore metadata that
        # describes them: "lenx" is the value, "_lenx_label" its caption.
        fields = attrs.keys.reject { |k| k.start_with?('_') }.sort
        out << { 'path' => path, 'name' => defn.name,
                 'fields' => fields.map { |f|
                   { 'name' => f, 'value' => attrs[f],
                     'label' => attrs["_#{f}_label"] || attrs["_#{f}_formlabel"],
                     'access' => attrs["_#{f}_access"],
                     'units' => attrs["_#{f}_units"],
                     'options' => attrs["_#{f}_options"],
                     'formula' => attrs["_#{f}_formula"] }
                 },
                 'behaviors' => attrs.select { |k, _|
                   k.start_with?('_') && !k.match(/^_[a-z0-9]+_(label|formlabel|access|units|options|formula|nextvalue|hasbehaviors)$/)
                 } }
      end
      defn.entities.grep(Sketchup::ComponentInstance).each do |inst|
        walk.call(inst.definition, path + [inst.definition.name], depth + 1)
      end
    end

    # Every definition, placed or not: a component saved as its own .skp often
    # has no instance in the file, so filtering on count_instances found none.
    model.definitions.each do |d|
      next if d.image?
      walk.call(d, [d.name], 0)
    end

    # The model itself can carry dynamic attributes too.
    mdict = model.attribute_dictionaries &&
            model.attribute_dictionaries['dynamic_attributes']
    if mdict
      attrs = {}
      mdict.each_pair { |k, v| attrs[k] = v }
      out << { 'path' => ['<model>'], 'name' => '<model>',
               'fields' => attrs.keys.reject { |k| k.start_with?('_') }.sort.map { |f|
                 { 'name' => f, 'value' => attrs[f], 'label' => attrs["_#{f}_label"],
                   'access' => attrs["_#{f}_access"], 'units' => attrs["_#{f}_units"],
                   'options' => attrs["_#{f}_options"], 'formula' => attrs["_#{f}_formula"] }
               }, 'behaviors' => {} }
    end

    log("definitions in file: #{model.definitions.count}, " \
        "top-level entities: #{model.entities.count}")
    model.definitions.each do |d|
      next if d.image?
      bb = d.bounds
      dict = d.attribute_dictionaries && d.attribute_dictionaries['dynamic_attributes']
      keys = dict ? dict.to_a.map(&:first).reject { |k| k.start_with?('_') } : []
      log(format('    defn %-26s inst=%-3d %6.1fx%6.1fx%6.1fmm  faces=%-5d dc=%s',
                 d.name.to_s[0, 26], d.count_instances,
                 bb.width.to_mm, bb.depth.to_mm, bb.height.to_mm,
                 d.entities.grep(Sketchup::Face).size,
                 keys.empty? ? '-' : keys.sort.join(',')))
    end
    model.entities.grep(Sketchup::ComponentInstance).each do |i|
      idict = i.attribute_dictionaries && i.attribute_dictionaries['dynamic_attributes']
      ikeys = idict ? idict.to_a.map(&:first).reject { |k| k.start_with?('_') } : []
      log("    top-level instance '#{i.definition.name}' inst-attrs: #{ikeys.sort.inspect}")
    end

    File.write(job['out'], JSON.pretty_generate(out))
    log("dc: #{out.size} definition(s) with dynamic attributes")
    out.each do |e|
      log("  #{e['path'].join(' > ')}")
      e['fields'].each do |f|
        bits = []
        bits << "= #{f['value'].inspect}"
        bits << "label '#{f['label']}'" if f['label']
        bits << "access #{f['access']}" if f['access']
        bits << "units #{f['units']}" if f['units']
        bits << "options #{f['options']}" if f['options']
        bits << "FORMULA #{f['formula']}" if f['formula']
        log("      #{f['name'].ljust(16)} #{bits.join('  ')}")
      end
      bh = e['behaviors'].reject { |k, v| v.to_s.empty? }
      log("      behaviors: #{bh.keys.sort.join(', ')}") unless bh.empty?
    end
    out.size
  end

  # Test harness for the rail extension: drives set_length without the GUI.
  def self.build_rail(job)
    model = Sketchup.active_model
    load File.join(Dir.home, '.local', 'share', 'stp2skp', 'mupro_rail.rb')

    # Wrap the loose top-level geometry into one component, as it would be
    # after inserting the rail into a model.
    inst = model.entities.grep(Sketchup::ComponentInstance).first
    if inst.nil?
      group = model.entities.add_group(model.entities.to_a)
      inst = group.to_component
      inst.definition.name = 'Rail'
    end

    job['lengths'].each do |want|
      ok = MuproRail.set_length(inst, want)
      got = inst.bounds.width.to_mm
      kids = inst.definition.entities.to_a.size
      log(format('    ask %7.1f mm -> %7.1f mm  (%s, %d parts, err %+.2f)',
                 want, got, ok ? 'ok' : 'FAILED', kids, got - want))
    end
    model.save(job['out'])
    job['lengths'].size
  end

  # Read-only survey of a component's sub-objects. Touches nothing, saves
  # nothing - it exists to identify the repeating module deterministically
  # instead of guessing at it.
  def self.survey(job)
    model = Sketchup.active_model
    rows = []
    model.entities.each_with_index do |e, i|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      bb = e.bounds
      d = e.respond_to?(:definition) ? e.definition : nil
      rows << { 'i' => i, 'kind' => e.class.name.split('::').last,
                'defn' => d ? d.name : '-',
                'w' => bb.width.to_mm, 'd' => bb.depth.to_mm, 'h' => bb.height.to_mm,
                'x0' => bb.min.x.to_mm, 'faces' => d ? d.entities.grep(Sketchup::Face).size : 0 }
    end
    loose = model.entities.reject do |e|
      e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
    end
    kinds = Hash.new(0)
    loose.each { |e| kinds[e.class.name.split('::').last] += 1 }

    log("survey: #{rows.size} sub-object(s), loose: #{kinds.inspect}")
    rows.sort_by { |r| r['x0'] }.each do |r|
      log(format('    x=%8.2f  %7.3f x %6.2f x %5.2f mm  %-9s %-14s faces=%d',
                 r['x0'], r['w'], r['d'], r['h'], r['kind'], r['defn'].to_s[0, 14], r['faces']))
    end
    widths = Hash.new(0)
    rows.each { |r| widths[r['w'].round(3)] += 1 }
    log("    widths: #{widths.sort_by { |_w, c| -c }.first(6).inspect}")
    File.write(job['out'], JSON.pretty_generate(rows))
    rows.size
  end

  # Test harness for the rail extension: drives set_length with no GUI.
  def self.build_rail(job)
    model = Sketchup.active_model
    load File.join(Dir.home, '.local', 'share', 'stp2skp', 'mupro_rail.rb')

    inst = model.entities.grep(Sketchup::ComponentInstance).first
    if inst.nil?
      group = model.entities.add_group(model.entities.to_a)
      inst = group.to_component
      inst.definition.name = 'Rail'
    end

    job['lengths'].each do |want|
      ok = MuproRail.set_length(inst, want)
      got = inst.bounds.width.to_mm
      links = inst.definition.entities.grep(Sketchup::ComponentInstance).size
      groups = inst.definition.entities.grep(Sketchup::Group).size
      log(format('    ask %8.2f -> %8.2f mm  err %+6.3f  %s  %d inst + %d group',
                 want, got, got - want, ok ? 'ok  ' : 'FAIL', links, groups))
    end
    model.save(job['out']) if job['out']
    job['lengths'].size
  end

  # ---- build the 5mm-step rail as a pure Dynamic Component ------------------
  #
  # Seven pre-cut end variants (5..35mm) nested in the rail; DC formulas reveal
  # exactly one. No Ruby runs afterwards - the extension is not needed.
  #
  # All geometry work happens at MODEL TOP LEVEL. Exploding and cutting inside
  # a definition that has a live instance is what crashed SketchUp three times.

  # Chain a set of edges into closed loops through shared vertices.
  def self.loops_from(edges)
    remaining = edges.select(&:valid?)
    found = []
    until remaining.empty?
      edge = remaining.shift
      chain = [edge]
      head = edge.end
      tail = edge.start
      progress = true
      while progress && head != tail
        progress = false
        remaining.each do |e|
          if e.start == head then head = e.end
          elsif e.end == head then head = e.start
          else next
          end
          chain << e
          remaining.delete(e)
          progress = true
          break
        end
      end
      found << chain if head == tail && chain.size >= 3
    end
    found
  end

  # Close every remaining open boundary, wherever it is. An edge with a single
  # adjacent face is a hole in the shell; a through-hole's edges always have
  # two, so genuine perforations are left alone.
  def self.close_open_edges(entities, passes = 6)
    made = 0
    passes.times do
      open_edges = entities.grep(Sketchup::Edge).select do |e|
        e.valid? && e.faces.size == 1
      end
      break if open_edges.empty?
      before = made

      loops_from(open_edges).each do |chain|
        begin
          made += 1 if entities.add_face(chain)
        rescue StandardError
          next
        end
      end
      break if made == before
    end
    made
  end

  def self.cap_cut_plane(entities, px, tol = 0.001)
    on_plane = entities.grep(Sketchup::Edge).select do |e|
      (e.start.position.x - px).abs < tol && (e.end.position.x - px).abs < tol &&
        e.faces.size < 2
    end
    return 0 if on_plane.empty?
    @last_boundary = on_plane.size
    made = 0
    loops_from(on_plane).each do |chain|
      begin
        made += 1 if entities.add_face(chain)
      rescue StandardError
        next
      end
    end
    made
  end

  # One link cut to `keep` long. `from` :start keeps the LEFT part (a normal
  # sawn end); :end keeps the RIGHT part, which is what lets the rail begin
  # part-way through the hole pattern.
  def self.cut_variant_once(model, template_def, keep, name, from = :start)
    tmp = model.entities.add_instance(template_def, IDENTITY)
    work = model.entities.add_group(
      tmp.explode.select { |e| e.valid? && e.respond_to?(:bounds) })
    ents = work.entities

    bb = work.bounds
    pad = 10.mm
    x = from == :start ? bb.min.x + keep : bb.max.x - keep

    # If the cut plane coincides with existing geometry, intersect_with makes
    # NO edges - a coplanar intersection is degenerate - and the cut side ends
    # up with no boundary at all. That is exactly what happens at 20mm, where
    # the plane lands on a hole wall. Nudge a hundredth of a millimetre off it;
    # far below the 5mm grid, so no placement maths is affected.
    coplanar = ents.grep(Sketchup::Face).any? do |f|
      f.vertices.all? { |v| (v.position.x - x).abs < 0.0005 }
    end
    if coplanar
      x += (from == :start ? 0.01.mm : -0.01.mm)
      log(format('      (cut plane was coplanar with existing geometry, ' \
                 'nudged to %.3fmm)', (from == :start ? x - bb.min.x : bb.max.x - x).to_mm))
    end

    blade = ents.add_group
    blade.entities.add_face(
      [[x, bb.min.y - pad, bb.min.z - pad], [x, bb.max.y + pad, bb.min.z - pad],
       [x, bb.max.y + pad, bb.max.z + pad], [x, bb.min.y - pad, bb.max.z + pad]]
        .map { |a, b, c| Geom::Point3d.new(a, b, c) })
    ents.intersect_with(true, IDENTITY, ents, IDENTITY, false, blade.entities.to_a)
    blade.erase! if blade.valid?

    # Snapshot to a plain array first, and judge by centre so edges lying in
    # the cut plane survive to be capped.
    doomed = ents.to_a.select do |e|
      next false unless e.valid? && e.respond_to?(:bounds)
      centre = (e.bounds.min.x + e.bounds.max.x) / 2.0
      from == :start ? centre > x + 0.0001 : centre < x - 0.0001
    end
    ents.erase_entities(doomed) unless doomed.empty?

    overhang = from == :start ? work.bounds.max.x - x : x - work.bounds.min.x
    if overhang > 0.02
      strict = ents.to_a.select do |e|
        next false unless e.valid? && e.respond_to?(:bounds)
        b = e.bounds
        from == :start ? b.max.x > x + 0.001 : b.min.x < x - 0.001
      end
      ents.erase_entities(strict) unless strict.empty?
      log(format('      (second pass: trimmed %.2fmm of overhang)', overhang.to_mm))
    end

    caps = cap_cut_plane(ents, x)
    extra = close_open_edges(ents)

    # Normalise every variant so its geometry begins at x = 0.
    minx = work.bounds.min.x
    if minx.abs > 1.0e-6
      ents.transform_entities(
        Geom::Transformation.new(Geom::Vector3d.new(-minx, 0, 0)), ents.to_a)
    end

    inst = work.to_component
    defn = inst.definition
    defn.name = model.definitions.unique_name(name)
    still_open = defn.entities.grep(Sketchup::Edge).count { |e| e.faces.size == 1 }
    [inst, defn, caps, still_open]
  end

  # Cut, then check. If the plane lands somewhere degenerate - coplanar with a
  # face, or tangent to a hole wall - intersect_with yields no edges and the cut
  # side comes back with no boundary at all. Detecting that geometrically is
  # unreliable, so judge the RESULT and retry a hair off the bad plane. 0.02mm
  # is far below the 5mm grid, so no placement maths changes.
  def self.make_end_variant(model, template_def, keep, name, from = :start)
    attempts = [keep, keep + 0.02.mm, keep - 0.02.mm]
    best = nil
    attempts.each_with_index do |try, i|
      inst, defn, caps, still_open = cut_variant_once(model, template_def, try, name, from)
      if caps >= 2 && still_open < 20
        log(format('    %-8s %6.2fmm  %3d faces, %d cap(s), %d edge(s) open%s',
                   name, defn.bounds.width.to_mm,
                   defn.entities.grep(Sketchup::Face).size, caps, still_open,
                   i.zero? ? '' : format('  (retried %+.2fmm)', (try - keep).to_mm)))
        best[0].erase! if best && best[0].valid?
        return [inst, defn]
      end
      log(format('    %-8s attempt %d: %d cap(s), %d edge(s) open - retrying',
                 name, i + 1, caps, still_open))
      if best.nil? || caps > best[2]
        best[0].erase! if best && best[0].valid?
        best = [inst, defn, caps]
      elsif inst.valid?
        inst.erase!
      end
    end
    log("    #{name}: all attempts degenerate, keeping the best")
    [best[0], best[1]]
  end

  # Pin a sub-component's size so the parent's scale cannot stretch it.
  # `shown_when` collapses the part along X while it is hidden. Hidden geometry
  # still counts toward the parent's bounding box, so a hidden 40mm link parked
  # at the origin kept the whole component 40mm wide however short it was set.
  def self.fix_size(inst, defn, shown_when = nil)
    return unless defn
    dc(inst, '_hasbehaviors' => 1.0)
    b = defn.bounds
    # FORMULAS in millimetres, not raw inch values. Raw values are what DC
    # stores internally, but the engine only re-applies a child's size when it
    # is formula-driven - with raw values the links stretched 14x under the
    # parent scale. Verified working in the 17:47 build.
    # BoundingBox naming: width = X, HEIGHT = Y, DEPTH = Z.
    w = b.width.to_mm.round(4).to_s
    lenx = shown_when ? "IF(#{shown_when},#{w},0.01)" : w
    dc(inst, 'lenx' => 0, '_lenx_formula' => lenx,
             'leny' => 0, '_leny_formula' => b.height.to_mm.round(4).to_s,
             'lenz' => 0, '_lenz_formula' => b.depth.to_mm.round(4).to_s)
  end

  def self.dc(entity, pairs)
    pairs.each { |k, v| entity.set_attribute('dynamic_attributes', k.to_s, v) }
  end

  # One cut at plane x. `keep` is :left (erase what is beyond) or :right.
  def self.trim(ents, x, keep)
    bb = ents.parent.bounds
    pad = 10.mm
    blade = ents.add_group
    blade.entities.add_face(
      [[x, bb.min.y - pad, bb.min.z - pad], [x, bb.max.y + pad, bb.min.z - pad],
       [x, bb.max.y + pad, bb.max.z + pad], [x, bb.min.y - pad, bb.max.z + pad]]
        .map { |a, b, c| Geom::Point3d.new(a, b, c) })
    ents.intersect_with(true, IDENTITY, ents, IDENTITY, false, blade.entities.to_a)
    blade.erase! if blade.valid?

    doomed = ents.to_a.select do |e|
      next false unless e.valid? && e.respond_to?(:bounds)
      centre = (e.bounds.min.x + e.bounds.max.x) / 2.0
      keep == :left ? centre > x + 0.0001 : centre < x - 0.0001
    end
    ents.erase_entities(doomed) unless doomed.empty?
    cap_cut_plane(ents, x)
  end

  # A slice of the link from from_x to to_x, cut and capped on both sides as
  # needed. Every cut here lands at a rail END, never mid-run, so no cap ever
  # blocks a hole. Retries a hair off-plane when a cut comes out degenerate.
  def self.make_slice(model, link_def, from_x, to_x, name)
    link_w = link_def.bounds.width
    best = nil
    [0.0, 0.02.mm, -0.02.mm].each_with_index do |nudge, attempt|
      tmp = model.entities.add_instance(link_def, IDENTITY)
      work = model.entities.add_group(
        tmp.explode.select { |e| e.valid? && e.respond_to?(:bounds) })
      ents = work.entities
      base = work.bounds.min.x
      caps = 0
      caps += trim(ents, base + to_x + nudge, :left)   if to_x < link_w - 0.001
      caps += trim(ents, base + from_x + nudge, :right) if from_x > 0.001
      close_open_edges(ents)

      faces = ents.grep(Sketchup::Face).size
      open_n = ents.grep(Sketchup::Edge).count { |e| e.valid? && e.faces.size == 1 }
      if faces > 4 && open_n < 20
        minx = work.bounds.min.x
        if minx.abs > 1.0e-6
          ents.transform_entities(
            Geom::Transformation.new(Geom::Vector3d.new(-minx, 0, 0)), ents.to_a)
        end
        inst = work.to_component
        inst.definition.name = model.definitions.unique_name(name)
        best[0].erase! if best && best[0].valid?
        return [inst, inst.definition, caps, open_n, attempt]
      end
      work.erase! if work.valid?
      best ||= nil
    end
    log("    #{name}: every attempt degenerate")
    nil
  end

  def self.build_variants(job)
    model = Sketchup.active_model
    step_mm = (job['step'] || 5).to_f
    original_len = model.bounds.width

    kids = model.entities.select do |e|
      e.valid? && (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance))
    end
    measured = kids.map { |k| { :o => k, :d => (k.respond_to?(:definition) ? k.definition : nil),
                                :x => k.bounds.min.x, :w => k.bounds.width } }
    family = measured.group_by { |m| m[:w].round(3) }.max_by { |_k, v| v.size }[1]
            .sort_by { |m| m[:x] }
    link_def = family.first[:d]
    link_w = family.first[:w]
    gaps = family.each_cons(2).map { |a, b| b[:x] - a[:x] }
    pitch = gaps.empty? ? link_w : gaps.min
    others = measured - family

    link_caps = close_open_edges(link_def.entities)
    link_open = link_def.entities.grep(Sketchup::Edge).count { |e| e.faces.size == 1 }
    log("    link capped: +#{link_caps} face(s), #{link_open} edge(s) still open")

    n = (pitch.to_mm / step_mm).round          # steps per link, 8
    step = pitch / n

    # Every slice (a, l): offset a steps, length l steps, a + l <= n.
    # (0, n) is the link itself, so it is not regenerated.
    slices = []
    (0...n).each do |a|
      (1..(n - a)).each do |l|
        next if a.zero? && l == n
        res = make_slice(model, link_def, a * step, (a + l) * step,
                         format('P%d_%d', a * step_mm, l * step_mm))
        next unless res
        inst, defn, caps, open_n, attempt = res
        slices << { :inst => inst, :defn => defn, :a => a, :l => l }
        log(format('    %-10s %6.2fmm  %3d faces, %d cap(s), %d open%s',
                   defn.name, defn.bounds.width.to_mm,
                   defn.entities.grep(Sketchup::Face).size, caps, open_n,
                   attempt.zero? ? '' : "  (retry #{attempt})"))
      end
    end
    log("    #{slices.size} slice(s) generated")

    # ---- assemble -----------------------------------------------------------
    holder = model.entities.add_group
    ents = holder.entities
    link_inst = ents.add_instance(link_def, IDENTITY)
    slice_ins = slices.map { |v| [v, ents.add_instance(v[:defn], IDENTITY)] }

    rail = holder.to_component
    rail_def = rail.definition
    rail_def.name = model.definitions.unique_name('MUPRO rail')

    dc(rail_def, '_name' => 'MUPRO rail', '_lengthunits' => 'MILLIMETERS',
                 '_hasbehaviors' => 1.0)
    dc(rail_def, 'pitch' => pitch.to_mm.round(4),
                 '_pitch_access' => 'VIEW', '_pitch_label' => 'Link pitch',
                 '_pitch_units' => 'MILLIMETERS')
    dc(rail_def, 'step' => 0, '_step_formula' => "pitch/#{n}",
                 '_step_access' => 'VIEW', '_step_label' => 'Step')
    dc(rail_def, 'total' => 0,
                 '_total_formula' => 'IF(ROUND(LenX/step)<1,1,ROUND(LenX/step))',
                 '_total_access' => 'VIEW', '_total_label' => 'Steps')
    dc(rail_def, 'start' => 0, '_start_access' => 'TEXTBOX',
                 '_start_label' => 'Pattern start (mm)',
                 '_start_formlabel' => 'Pattern start (mm)')
    dc(rail_def, 'startstep' => 0,
                 '_startstep_formula' =>
                   "ROUND(start/step)-FLOOR(ROUND(start/step)/#{n})*#{n}",
                 '_startstep_access' => 'VIEW', '_startstep_label' => 'Start step')
    # Steps consumed by the leading slice - capped at what is actually left, so
    # a short offset rail no longer grows to fit a full-size start piece.
    dc(rail_def, 'head' => 0,
                 '_head_formula' =>
                   "IF(startstep=0,0,IF(total<#{n}-startstep,total,#{n}-startstep))",
                 '_head_access' => 'VIEW', '_head_label' => 'Lead steps')
    dc(rail_def, 'rest' => 0, '_rest_formula' => 'total-head',
                 '_rest_access' => 'VIEW', '_rest_label' => 'Steps after lead')
    dc(rail_def, 'whole' => 0, '_whole_formula' => "FLOOR(rest/#{n})",
                 '_whole_access' => 'VIEW', '_whole_label' => 'Whole links')
    dc(rail_def, 'idx' => 0, '_idx_formula' => "rest-whole*#{n}",
                 '_idx_access' => 'VIEW', '_idx_label' => 'Tail steps')
    dc(rail_def, 'x0' => 0, '_x0_formula' => 'head*step',
                 '_x0_access' => 'VIEW', '_x0_label' => 'Body offset')
    dc(rail_def, '_lenx_label' => 'Length', '_lenx_formlabel' => 'Length',
                 '_lenx_units' => 'MILLIMETERS', '_lenx_access' => 'TEXTBOX')
    dc(rail_def, 'scaletool' => '126')

    dc(link_inst, '_lengthunits' => 'MILLIMETERS')
    fix_size(link_inst, link_def, 'Parent!whole>0')
    dc(link_inst, '_name' => 'Link', 'copies' => 0,
                  '_copies_formula' => 'IF(Parent!whole<1,0,Parent!whole-1)',
                  'x' => 0, '_x_formula' => 'Parent!x0+copy*Parent!pitch',
                  'hidden' => 0, '_hidden_formula' => 'IF(Parent!whole<1,1,0)')

    slice_ins.each do |v, inst|
      shown = if v[:a].zero?
                # Tail slice: used when the run ends part-way through a link.
                "Parent!idx=#{v[:l]}"
              else
                # Lead slice: the rail starts this far into the pattern.
                "Parent!startstep=#{v[:a]}"
              end
      cond = v[:a].zero? ? shown : "IF(Parent!startstep=#{v[:a]},Parent!head=#{v[:l]},0)"
      dc(inst, '_lengthunits' => 'MILLIMETERS')
      fix_size(inst, v[:defn], v[:a].zero? ? shown : "Parent!head=#{v[:l]}")
      place = v[:a].zero? ? 'Parent!x0+Parent!whole*Parent!pitch' : '0'
      dc(inst, '_name' => v[:defn].name,
               'x' => 0,
               '_x_formula' => v[:a].zero? ? "IF(#{shown},#{place},0)" : '0',
               'hidden' => 1,
               '_hidden_formula' =>
                 v[:a].zero? ? "IF(#{shown},0,1)" :
                   "IF(Parent!startstep=#{v[:a]},IF(Parent!head=#{v[:l]},0,1),1)")
    end

    current = rail.bounds.width
    if current > 0 && (original_len - current).abs > 0.1
      rail.transform!(Geom::Transformation.scaling(
                        rail.bounds.min, original_len / current, 1, 1))
      log("    scaled to natural length #{original_len.to_mm.round(2)}mm")
    end

    src = rail_def.attribute_dictionary('dynamic_attributes')
    src.each_pair { |k, v| rail.set_attribute('dynamic_attributes', k, v) } if src

    if defined?($dc_observers) && $dc_observers
      begin
        $dc_observers.get_latest_class.redraw_with_undo(rail)
        log('  dc engine: evaluated')
      rescue StandardError => e
        log("  dc redraw failed: #{e.message}")
      end
    else
      log('  dc engine NOT available')
    end

    %w[pitch step total start startstep head rest whole idx x0 scaletool].each do |k|
      log(format('    %-10s = %s', k, rail.get_attribute('dynamic_attributes', k).inspect))
    end
    shown_e = rail_def.entities.select { |e| e.respond_to?(:hidden?) && !e.hidden? }
    dims = shown_e.map do |e|
      b = e.bounds
      [b.width.to_mm.round(2), b.height.to_mm.round(2), b.depth.to_mm.round(2)]
    end.uniq.sort
    log("    LenX bounds = #{rail.bounds.width.to_mm.round(2)}mm, visible = #{shown_e.size}")
    log("    visible sizes: #{dims.inspect} mm")
    extent = rail_def.entities.select { |e| e.respond_to?(:bounds) }
                     .map { |e| e.bounds.max.x.to_mm.round(2) }.max
    log("    furthest extent incl. hidden: #{extent}mm")
    whole = rail.get_attribute('dynamic_attributes', 'whole').to_f
    log(whole >= 1 ? '    formula chain OK' : '    *** CHAIN SUSPECT')

    slices.each { |v| v[:inst].erase! if v[:inst].valid? }
    family.each { |m| m[:o].erase! if m[:o].valid? }
    others.each { |m| m[:o].erase! if m[:o].valid? }

    frame(model)
    model.save(job['out'])
    slices.size
  end

  def self.run
    return unless File.exist?(JOB)
    job = JSON.parse(File.read(JOB))
    # Consume the job immediately so a crash can't turn it into a boot loop.
    File.delete(JOB)

    if job['mode'] == 'variants'
      begin
        n = build_variants(job)
        log("variants complete: #{n}")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'n' => n }] }))
      rescue StandardError => e
        log("variants FAILED: #{e.message}")
        log("  #{e.backtrace.first(3).join(' | ')}") if e.backtrace
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'rail'
      begin
        n = build_rail(job)
        log("rail: #{n} length(s) tested")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true }] }))
      rescue StandardError => e
        log("rail FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'variants'
      begin
        n = build_variants(job)
        log("variants complete: #{n}")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'n' => n }] }))
      rescue StandardError => e
        log("variants FAILED: #{e.message}")
        log("  #{e.backtrace.first(3).join(' | ')}") if e.backtrace
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'rail'
      begin
        n = build_rail(job)
        log("rail: #{n} length(s) tested")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true }] }))
      rescue StandardError => e
        log("rail FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'survey'
      begin
        n = survey(job)
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'rows' => n }] }))
      rescue StandardError => e
        log("survey FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'describe'
      begin
        n = describe_dc(job)
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'count' => n }] }))
      rescue StandardError => e
        log("describe FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'bom'
      begin
        n = build_bom(job)
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'rows' => n }] }))
      rescue StandardError => e
        log("bom FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'profiles'
      begin
        n = build_profiles(job)
        log("profiles complete: #{n} components")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'count' => n }] }))
      rescue StandardError => e
        log("profiles FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'brackets'
      begin
        n = build_brackets(job)
        log("brackets complete: #{n} components written")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'count' => n }] }))
      rescue StandardError => e
        log("brackets FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'pipes'
      begin
        n = build_pipes(job)
        log("pipes complete: #{job['pipes'].size} sizes, #{n} files written")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'count' => n }] }))
      rescue StandardError => e
        log("pipes FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end

    if job['mode'] == 'sheet'
      begin
        placed = build_sheet(job)
        frame(Sketchup.active_model)
        Sketchup.active_model.save(job['out'])
        log("sheet complete: #{placed} components -> #{File.basename(job['out'])}")
        File.write(DONE, JSON.generate({ 'results' => [{ 'ok' => true, 'placed' => placed }] }))
      rescue StandardError => e
        log("sheet FAILED: #{e.message}")
        File.write(DONE, JSON.generate({ 'results' => [], 'error' => e.message }))
      end
      return
    end
    @merge = job['merge'] != false
    @smooth_angle = (job['smooth_angle'] || 20).to_f
    @guides = job['guides'] != false
    log("starting batch of #{job['items'].size}")

    results = []
    job['items'].each_with_index do |item, i|
      src, dst = item['src'], item['dst']
      begin
        model = Sketchup.active_model
        # Clear at the START of each item, so the final model is left clean
        # and quitting never raises a "save changes?" modal.
        model.entities.clear!
        model.definitions.purge_unused
        model.materials.purge_unused
        model.layers.purge_unused if model.layers.respond_to?(:purge_unused)
        model.styles.purge_unused if model.styles.respond_to?(:purge_unused)

        faces = build(model, src)
        raise 'built no faces' if faces.zero?

        # Frame the geometry. zoom_extents depends on the view actually
        # rendering, which never happens when a tiling WM parks the window
        # off-screen - so compute the camera from the bounds instead.
        frame(model)
        model.save(dst)

        bb = model.bounds
        log("[#{i + 1}/#{job['items'].size}] #{File.basename(dst)} ok " \
            "(#{faces} faces, #{@snaps_added} snaps, " \
            "#{bb.width.to_mm.round(1)}x#{bb.height.to_mm.round(1)}x" \
            "#{bb.depth.to_mm.round(1)}mm)")
        results << { 'dst' => dst, 'ok' => true, 'faces' => faces }
      rescue StandardError => e
        log("[#{i + 1}/#{job['items'].size}] #{File.basename(src)} FAILED: #{e.message}")
        results << { 'src' => src, 'ok' => false, 'error' => e.message }
      end
    end

    File.write(DONE, JSON.generate({ 'results' => results }))
    log("batch complete: #{results.count { |r| r['ok'] }}/#{results.size} converted")
  end
end

unless file_loaded?(__FILE__)
  # Log at load time regardless of whether a job is pending: a silent log is
  # otherwise indistinguishable from the plugin never loading at all.
  begin
    STP2SKP.log("plugin file loaded (job pending: #{File.exist?(STP2SKP::JOB)})")
  rescue StandardError
    nil
  end
  UI.start_timer(1.0, false) { STP2SKP.arm }
  file_loaded(__FILE__)
end
