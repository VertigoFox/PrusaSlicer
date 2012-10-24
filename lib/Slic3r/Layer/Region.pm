package Slic3r::Layer::Region;
use Moo;

use Math::Clipper ':all';
use Slic3r::ExtrusionPath ':roles';
use Slic3r::Geometry qw(scale shortest_path);
use Slic3r::Geometry::Clipper qw(safety_offset union_ex diff_ex intersection_ex);
use Slic3r::Surface ':types';

has 'layer' => (
    is          => 'ro',
    weak_ref    => 1,
    required    => 1,
    handles     => [qw(id slice_z print_z height flow)],
);
has 'region'            => (is => 'ro', required => 1);
has 'perimeter_flow'    => (is => 'lazy');
has 'infill_flow'       => (is => 'lazy');

# collection of spare segments generated by slicing the original geometry;
# these need to be merged in continuos (closed) polylines
has 'lines' => (is => 'rw', default => sub { [] });

# collection of surfaces generated by slicing the original geometry
has 'slices' => (is => 'rw', default => sub { [] });

# collection of polygons or polylines representing thin walls contained 
# in the original geometry
has 'thin_walls' => (is => 'rw', default => sub { [] });

# collection of polygons or polylines representing thin infill regions that
# need to be filled with a medial axis
has 'thin_fills' => (is => 'rw', default => sub { [] });

# collection of expolygons generated by offsetting the innermost perimeter(s)
# they represent boundaries of areas to fill, typed (top/bottom/internal)
has 'surfaces' => (is => 'rw', default => sub { [] });

# collection of surfaces for infill generation. the difference between surfaces
# fill_surfaces is that this one honors fill_density == 0 and turns small internal
# surfaces into solid ones
has 'fill_surfaces' => (is => 'rw', default => sub { [] });

# ordered collection of extrusion paths/loops to build all perimeters
has 'perimeters' => (is => 'rw', default => sub { [] });

# ordered collection of extrusion paths to fill surfaces
has 'fills' => (is => 'rw', default => sub { [] });

sub _build_perimeter_flow {
    my $self = shift;
    return $self->id == 0
        ? $self->region->first_layer_flows->{perimeter}
        : $self->region->flows->{perimeter}
}

sub _build_infill_flow {
    my $self = shift;
    return $self->id == 0
        ? $self->region->first_layer_flows->{infill}
        : $self->region->flows->{infill}
}

# build polylines from lines
sub make_surfaces {
    my $self = shift;
    my ($loops) = @_;
    
    return if !@$loops;    
    {
        my $safety_offset = scale 0.1;
        # merge everything
        my $expolygons = [ map $_->offset_ex(-$safety_offset), @{union_ex(safety_offset($loops, $safety_offset))} ];
        
        Slic3r::debugf "  %d surface(s) having %d holes detected from %d polylines\n",
            scalar(@$expolygons), scalar(map $_->holes, @$expolygons), scalar(@$loops);
        
        $self->slices([
            map Slic3r::Surface->new(expolygon => $_, surface_type => S_TYPE_INTERNAL),
                @$expolygons
        ]);
    }
    
    # the contours must be offsetted by half extrusion width inwards
    {
        my $distance = $self->perimeter_flow->scaled_width / 2;
        my @surfaces = @{$self->slices};
        @{$self->slices} = ();
        foreach my $surface (@surfaces) {
            push @{$self->slices}, map Slic3r::Surface->new
                (expolygon => $_, surface_type => S_TYPE_INTERNAL),
                map $_->offset_ex(+$distance),
                $surface->expolygon->offset_ex(-2*$distance);
        }
        
        # now detect thin walls by re-outgrowing offsetted surfaces and subtracting
        # them from the original slices
        my $outgrown = Math::Clipper::offset([ map $_->p, @{$self->slices} ], $distance);
        my $diff = diff_ex(
            [ map $_->p, @surfaces ],
            $outgrown,
            1,
        );
        
        $self->thin_walls([]);
        if (@$diff) {
            my $area_threshold = $self->perimeter_flow->scaled_spacing ** 2;
            @$diff = grep $_->area > ($area_threshold), @$diff;
            
            @{$self->thin_walls} = map $_->medial_axis($self->perimeter_flow->scaled_width), @$diff;
            
            Slic3r::debugf "  %d thin walls detected\n", scalar(@{$self->thin_walls}) if @{$self->thin_walls};
        }
    }
    
    if (0) {
        require "Slic3r/SVG.pm";
        Slic3r::SVG::output(undef, "surfaces.svg",
            polygons        => [ map $_->contour, @{$self->slices} ],
            red_polygons    => [ map $_->p, map @{$_->holes}, @{$self->slices} ],
        );
    }
}

sub make_perimeters {
    my $self = shift;
    
    my $gap_area_threshold = $self->perimeter_flow->scaled_width ** 2;
    
    # this array will hold one arrayref per original surface (island);
    # each item of this arrayref is an arrayref representing a depth (from outer
    # perimeters to inner); each item of this arrayref is an ExPolygon:
    # @perimeters = (
    #    [ # first island
    #        [ Slic3r::ExPolygon, Slic3r::ExPolygon... ],  #depth 0: outer loop
    #        [ Slic3r::ExPolygon, Slic3r::ExPolygon... ],  #depth 1: inner loop
    #    ],
    #    [ # second island
    #        ...
    #    ]
    # )
    my @perimeters = ();  # one item per depth; each item
    
    # organize islands using a shortest path search
    my @surfaces = @{shortest_path([
        map [ $_->contour->[0], $_ ], @{$self->slices},
    ])};
    
    $self->perimeters([]);
    $self->surfaces([]);
    $self->thin_fills([]);
    
    # for each island:
    foreach my $surface (@surfaces) {
        my @last_offsets = ($surface->expolygon);
        
        # experimental hole compensation (see ArcCompensation in the RepRap wiki)
        if (0) {
            foreach my $hole ($last_offsets[0]->holes) {
                my $circumference = abs($hole->length);
                next unless $circumference <= &Slic3r::SMALL_PERIMETER_LENGTH;
                # this compensation only works for circular holes, while it would 
                # overcompensate for hexagons and other shapes having straight edges.
                # so we require a minimum number of vertices.
                next unless $circumference / @$hole >= 3 * $Slic3r::flow->scaled_width;
                
                # revert the compensation done in make_surfaces() and get the actual radius
                # of the hole
                my $radius = ($circumference / PI / 2) - $self->perimeter_flow->scaled_spacing/2;
                my $new_radius = ($self->perimeter_flow->scaled_width + sqrt(($self->perimeter_flow->scaled_width ** 2) + (4*($radius**2)))) / 2;
                # holes are always turned to contours, so reverse point order before and after
                $hole->reverse;
                my @offsetted = $hole->offset(+ ($new_radius - $radius));
                # skip arc compensation when hole is not round (thus leads to multiple offsets)
                @$hole = map Slic3r::Point->new($_), @{ $offsetted[0] } if @offsetted == 1;
                $hole->reverse;
            }
        }
        
        my $distance = $self->perimeter_flow->scaled_spacing;
        my @gaps = ();
        
        # generate perimeters inwards (loop 0 is the external one)
        my $loop_number = $Slic3r::Config->perimeters + ($surface->additional_inner_perimeters || 0);
        push @perimeters, [[@last_offsets]];
        for (my $loop = 1; $loop < $loop_number; $loop++) {
            # offsetting a polygon can result in one or many offset polygons
            my @new_offsets = ();
            foreach my $expolygon (@last_offsets) {
                my @offsets = map $_->offset_ex(+0.5*$distance), $expolygon->noncollapsing_offset_ex(-1.5*$distance);
                push @new_offsets, @offsets;
                
                # where the above check collapses the expolygon, then there's no room for an inner loop
                # and we can extract the gap for later processing
                my $diff = diff_ex(
                    [ map @$_, $expolygon->offset_ex(-0.5*$distance) ],
                    [ map @$_, map $_->offset_ex(+0.5*$distance), @offsets ],  # should these be offsetted in a single pass?
                );
                push @gaps, grep $_->area >= $gap_area_threshold, @$diff;
            }
            @last_offsets = @new_offsets;
            
            last if !@last_offsets;
            push @{ $perimeters[-1] }, [@last_offsets];
        }
        
        # create one more offset to be used as boundary for fill
        {
            my @fill_boundaries = map $_->offset_ex(-$distance), @last_offsets;
            $_->simplify(scale &Slic3r::RESOLUTION) for @fill_boundaries;
            push @{ $self->surfaces }, @fill_boundaries;
        }
        
        # fill gaps using dynamic extrusion width
        {
            # detect the small gaps that we need to treat like thin polygons,
            # thus generating the skeleton and using it to fill them
            my $w = $self->perimeter_flow->width;
            my @widths = (1.5 * $w, $w, 0.5 * $w, 0.2 * $w);
            foreach my $width (@widths) {
                my $scaled_width = scale $width;
                
                # extract the gaps having this width
                my @this_width = map $_->offset_ex(+0.5*$scaled_width), map $_->noncollapsing_offset_ex(-0.5*$scaled_width), @gaps;
                
                # fill them
                my %path_args = (
                    role            => EXTR_ROLE_SOLIDFILL,
                    flow_spacing    => $self->perimeter_flow->clone(width => $width)->spacing,
                );
                push @{ $self->thin_fills }, map {
                    $_->isa('Slic3r::Polygon')
                        ? (map $_->pack, Slic3r::ExtrusionLoop->new(polygon => $_, %path_args)->split_at_first_point)  # we should keep these as loops
                        : Slic3r::ExtrusionPath->pack(polyline => $_, %path_args),
                } map $_->medial_axis($scaled_width), @this_width;
            
                Slic3r::debugf "  %d gaps filled with extrusion width = %s\n", scalar @this_width, $width
                    if @{ $self->thin_fills };
                
                # check what's left
                @gaps = @{diff_ex(
                    [ map @$_, @gaps ],
                    [ map @$_, @this_width ],
                )};
            }
        }
    }
    
    # process one island (original surface) at time
    foreach my $island (@perimeters) {
        # do holes starting from innermost one
        my @holes = ();
        my %is_external = ();
        my @hole_depths = map [ map $_->holes, @$_ ], @$island;
        
        # organize the outermost hole loops using a shortest path search
        @{$hole_depths[0]} = @{shortest_path([
            map [ $_->[0], $_ ], @{$hole_depths[0]},
        ])};
        
        CYCLE: while (map @$_, @hole_depths) {
            shift @hole_depths while !@{$hole_depths[0]};
            
            # take first available hole
            push @holes, shift @{$hole_depths[0]};
            $is_external{$#holes} = 1;
            
            my $current_depth = 0;
            while (1) {
                $current_depth++;
                
                # look for the hole containing this one if any
                next CYCLE if !$hole_depths[$current_depth];
                my $parent_hole;
                for (@{$hole_depths[$current_depth]}) {
                    if ($_->encloses_point($holes[-1]->[0])) {
                        $parent_hole = $_;
                        last;
                    }
                }
                next CYCLE if !$parent_hole;
                
                # look for other holes contained in such parent
                for (@{$hole_depths[$current_depth-1]}) {
                    if ($parent_hole->encloses_point($_->[0])) {
                        # we have a sibling, so let's move onto next iteration
                        next CYCLE;
                    }
                }
                
                push @holes, $parent_hole;
                @{$hole_depths[$current_depth]} = grep $_ ne $parent_hole, @{$hole_depths[$current_depth]};
            }
        }
        
        # do holes, then contours starting from innermost one
        $self->_add_perimeter($holes[$_], $is_external{$_} ? EXTR_ROLE_EXTERNAL_PERIMETER : undef)
            for reverse 0 .. $#holes;
        for my $depth (reverse 0 .. $#$island) {
            my $role = $depth == $#$island ? EXTR_ROLE_CONTOUR_INTERNAL_PERIMETER
                : $depth == 0 ? EXTR_ROLE_EXTERNAL_PERIMETER
                : EXTR_ROLE_PERIMETER;
            $self->_add_perimeter($_, $role) for map $_->contour, @{$island->[$depth]};
        }
    }
    
    # add thin walls as perimeters
    {
        my @thin_paths = ();
        my %properties = (
            role            => EXTR_ROLE_EXTERNAL_PERIMETER,
            flow_spacing    => $self->perimeter_flow->spacing,
        );
        for (@{ $self->thin_walls }) {
            push @thin_paths, $_->isa('Slic3r::Polygon')
                ? Slic3r::ExtrusionLoop->pack(polygon => $_, %properties)
                : Slic3r::ExtrusionPath->pack(polyline => $_, %properties);
        }
        my $collection = Slic3r::ExtrusionPath::Collection->new(paths => \@thin_paths);
        push @{ $self->perimeters }, $collection->shortest_path;
    }
}

sub _add_perimeter {
    my $self = shift;
    my ($polygon, $role) = @_;
    
    return unless $polygon->is_printable($self->perimeter_flow->width);
    push @{ $self->perimeters }, Slic3r::ExtrusionLoop->pack(
        polygon         => $polygon,
        role            => (abs($polygon->length) <= &Slic3r::SMALL_PERIMETER_LENGTH) ? EXTR_ROLE_SMALLPERIMETER : ($role // EXTR_ROLE_PERIMETER),  #/
        flow_spacing    => $self->perimeter_flow->spacing,
    );
}

sub prepare_fill_surfaces {
    my $self = shift;
    
    my @surfaces = @{$self->surfaces};
    
    # if no solid layers are requested, turn top/bottom surfaces to internal
    # note that this modifies $self->surfaces in place
    if ($Slic3r::Config->solid_layers == 0) {
        $_->surface_type(S_TYPE_INTERNAL) for grep $_->surface_type != S_TYPE_INTERNAL, @surfaces;
    }
    
    # if hollow object is requested, remove internal surfaces
    if ($Slic3r::Config->fill_density == 0) {
        @surfaces = grep $_->surface_type != S_TYPE_INTERNAL, @surfaces;
    }
    
    # remove unprintable regions (they would slow down the infill process and also cause
    # some weird failures during bridge neighbor detection)
    {
        my $distance = $self->infill_flow->scaled_spacing / 2;
        @surfaces = map {
            my $surface = $_;
            
            # offset inwards
            my @offsets = $surface->expolygon->offset_ex(-$distance);
            @offsets = @{union_ex(Math::Clipper::offset([ map @$_, @offsets ], $distance, 100000, JT_MITER))};
            map Slic3r::Surface->new(
                expolygon => $_,
                surface_type => $surface->surface_type,
            ), @offsets;
        } @surfaces;
    }
        
    # turn too small internal regions into solid regions
    {
        my $min_area = scale scale $Slic3r::Config->solid_infill_below_area; # scaling an area requires two calls!
        my @small = grep $_->surface_type == S_TYPE_INTERNAL && $_->expolygon->contour->area <= $min_area, @surfaces;
        $_->surface_type(S_TYPE_INTERNALSOLID) for @small;
        Slic3r::debugf "identified %d small solid surfaces at layer %d\n", scalar(@small), $self->id if @small > 0;
    }
    
    $self->fill_surfaces([@surfaces]);
}

# make bridges printable
sub process_bridges {
    my $self = shift;
    
    # no bridges are possible if we have no internal surfaces
    return if $Slic3r::Config->fill_density == 0;
    
    my @bridges = ();
    
    # a bottom surface on a layer > 0 is either a bridge or a overhang 
    # or a combination of both; any top surface is a candidate for
    # reverse bridge processing
    
    my @solid_surfaces = grep {
        ($_->surface_type == S_TYPE_BOTTOM && $self->id > 0) || $_->surface_type == S_TYPE_TOP
    } @{$self->fill_surfaces} or return;
    
    my @internal_surfaces = grep { $_->surface_type == S_TYPE_INTERNAL || $_->surface_type == S_TYPE_INTERNALSOLID } @{$self->slices};
    
    SURFACE: foreach my $surface (@solid_surfaces) {
        my $expolygon = $surface->expolygon->safety_offset;
        my $description = $surface->surface_type == S_TYPE_BOTTOM ? 'bridge/overhang' : 'reverse bridge';
        
        # offset the contour and intersect it with the internal surfaces to discover 
        # which of them has contact with our bridge
        my @supporting_surfaces = ();
        my ($contour_offset) = $expolygon->contour->offset(scale $self->flow->spacing * sqrt(2));
        foreach my $internal_surface (@internal_surfaces) {
            my $intersection = intersection_ex([$contour_offset], [$internal_surface->p]);
            if (@$intersection) {
                push @supporting_surfaces, $internal_surface;
            }
        }
        
        if (0) {
            require "Slic3r/SVG.pm";
            Slic3r::SVG::output(undef, "bridge_surfaces.svg",
                green_polygons  => [ map $_->p, @supporting_surfaces ],
                red_polygons    => [ @$expolygon ],
            );
        }
        
        Slic3r::debugf "Found $description on layer %d with %d support(s)\n", 
            $self->id, scalar(@supporting_surfaces);
        
        next SURFACE unless @supporting_surfaces;
        
        my $bridge_angle = undef;
        if ($surface->surface_type == S_TYPE_BOTTOM) {
            # detect optimal bridge angle
            
            my $bridge_over_hole = 0;
            my @edges = ();  # edges are POLYLINES
            foreach my $supporting_surface (@supporting_surfaces) {
                my @surface_edges = map $_->clip_with_polygon($contour_offset),
                    ($supporting_surface->contour, $supporting_surface->holes);
                
                if (@supporting_surfaces == 1 && @surface_edges == 1
                    && @{$supporting_surface->contour} == @{$surface_edges[0]}) {
                    $bridge_over_hole = 1;
                }
                push @edges, grep { @$_ } @surface_edges;
            }
            Slic3r::debugf "  Bridge is supported on %d edge(s)\n", scalar(@edges);
            Slic3r::debugf "  and covers a hole\n" if $bridge_over_hole;
            
            if (0) {
                require "Slic3r/SVG.pm";
                Slic3r::SVG::output(undef, "bridge_edges.svg",
                    polylines       => [ map $_->p, @edges ],
                );
            }
            
            if (@edges == 2) {
                my @chords = map Slic3r::Line->new($_->[0], $_->[-1]), @edges;
                my @midpoints = map $_->midpoint, @chords;
                my $line_between_midpoints = Slic3r::Line->new(@midpoints);
                $bridge_angle = Slic3r::Geometry::rad2deg_dir($line_between_midpoints->direction);
            } elsif (@edges == 1) {
                # TODO: this case includes both U-shaped bridges and plain overhangs;
                # we need a trapezoidation algorithm to detect the actual bridged area
                # and separate it from the overhang area.
                # in the mean time, we're treating as overhangs all cases where
                # our supporting edge is a straight line
                if (@{$edges[0]} > 2) {
                    my $line = Slic3r::Line->new($edges[0]->[0], $edges[0]->[-1]);
                    $bridge_angle = Slic3r::Geometry::rad2deg_dir($line->direction);
                }
            } elsif (@edges) {
                my $center = Slic3r::Geometry::bounding_box_center([ map @$_, @edges ]);
                my $x = my $y = 0;
                foreach my $point (map @$, @edges) {
                    my $line = Slic3r::Line->new($center, $point);
                    my $dir = $line->direction;
                    my $len = $line->length;
                    $x += cos($dir) * $len;
                    $y += sin($dir) * $len;
                }
                $bridge_angle = Slic3r::Geometry::rad2deg_dir(atan2($y, $x));
            }
            
            Slic3r::debugf "  Optimal infill angle of bridge on layer %d is %d degrees\n",
                $self->id, $bridge_angle if defined $bridge_angle;
        }
        
        # now, extend our bridge by taking a portion of supporting surfaces
        {
            # offset the bridge by the specified amount of mm (minimum 3)
            my $bridge_overlap = scale 3;
            my ($bridge_offset) = $expolygon->contour->offset($bridge_overlap);
            
            # calculate the new bridge
            my $intersection = intersection_ex(
                [ @$expolygon, map $_->p, @supporting_surfaces ],
                [ $bridge_offset ],
            );
            
            push @bridges, map Slic3r::Surface->new(
                expolygon => $_,
                surface_type => $surface->surface_type,
                bridge_angle => $bridge_angle,
            ), @$intersection;
        }
    }
    
    # now we need to merge bridges to avoid overlapping
    {
        # build a list of unique bridge types
        my @surface_groups = Slic3r::Surface->group(@bridges);
        
        # merge bridges of the same type, removing any of the bridges already merged;
        # the order of @surface_groups determines the priority between bridges having 
        # different surface_type or bridge_angle
        @bridges = ();
        foreach my $surfaces (@surface_groups) {
            my $union = union_ex([ map $_->p, @$surfaces ]);
            my $diff = diff_ex(
                [ map @$_, @$union ],
                [ map $_->p, @bridges ],
            );
            
            push @bridges, map Slic3r::Surface->new(
                expolygon => $_,
                surface_type => $surfaces->[0]->surface_type,
                bridge_angle => $surfaces->[0]->bridge_angle,
            ), @$union;
        }
    }
    
    # apply bridges to layer
    {
        my @surfaces = @{$self->fill_surfaces};
        @{$self->fill_surfaces} = ();
        
        # intersect layer surfaces with bridges to get actual bridges
        foreach my $bridge (@bridges) {
            my $actual_bridge = intersection_ex(
                [ map $_->p, @surfaces ],
                [ $bridge->p ],
            );
            
            push @{$self->fill_surfaces}, map Slic3r::Surface->new(
                expolygon => $_,
                surface_type => $bridge->surface_type,
                bridge_angle => $bridge->bridge_angle,
            ), @$actual_bridge;
        }
        
        # difference between layer surfaces and bridges are the other surfaces
        foreach my $group (Slic3r::Surface->group(@surfaces)) {
            my $difference = diff_ex(
                [ map $_->p, @$group ],
                [ map $_->p, @bridges ],
            );
            push @{$self->fill_surfaces}, map Slic3r::Surface->new(
                expolygon => $_,
                surface_type => $group->[0]->surface_type), @$difference;
        }
    }
}

1;
