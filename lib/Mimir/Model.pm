package Mimir::Model;
use Mojo::Base -base;
use Mimir::Schema;

has schema => sub {
    # TODO: config connect settings
    return Mimir::Schema->connect('dbi:SQLite:' . ($ENV{MOJO_MODE} || 'test') . '.db');
};

sub _get_nav {
    my $self = shift;
    my $stem = shift;

    my @stems;
    my $stems_rs = $self->schema->resultset('Stem')->search();
    while (my $stem_rs = $stems_rs->next) {
        push @stems, {
            stem_id => $stem_rs->stem_id,
            title   => $stem_rs->title,
            active  => ($stem && $stem->id == $stem_rs->stem_id) ? 1 : 0,
        };
    }

    my @branches;
    if($stem) {
        my $branches_rs = $stem->branches;
        while (my $branch_rs = $branches_rs->next) {
            push @branches, { branch_id => $branch_rs->branch_id, title => $branch_rs->title };
        }
    }

    return { stems => \@stems, branches => \@branches };
}

sub stem_list {
    my $self = shift;

    my @stems;
    my $stems_rs = $self->schema->resultset('Stem')->search();
    while (my $stem_rs = $stems_rs->next) {
        push @stems, { stem_id => $stem_rs->stem_id, title => $stem_rs->title };
    }

    return(
        nav   => $self->_get_nav(),
        stems => \@stems,
    );
}

sub stem_view {
    my $self = shift;
    return(
        nav => $self->_get_nav($self->schema->resultset('Stem')->single({stem_id => shift}))
    );
}

sub stem_add {
    my $self = shift;
    my %args = @_;

    my $stem_rs = $self->schema->resultset('Stem')->create({
        title => $args{title},
    });

    return(
        nav => $self->_get_nav($stem_rs),
    );
}

sub branch_add {
    my $self = shift;
    my %args = @_;

    my $stem_id = $args{stem_id};
    my $weight  = $self->schema
                       ->resultset('Branch')
                       ->search({stem_id => $stem_id})
                       ->get_column('weight')
                       ->max;

    my $branch_rs = $self->schema->resultset('Branch')->create({
        stem_id => $stem_id,
        title   => $args{title},
        weight  => ++$weight,
    });

    return(
        nav       => $self->_get_nav($branch_rs->stem),
        branch_id => $branch_rs->branch_id,
        title     => $branch_rs->title,
        nodes     => [ ],
    );
}

sub branch_view {
    my $self = shift;
    my $branch_rs = $self->schema->resultset('Branch')->single({branch_id => shift});

    my @nodes;
    my $nodes_rs = $branch_rs->nodes;
    while (my $node_rs = $nodes_rs->next) {
        push @nodes, { $self->node_view($node_rs->node_id) };
    }

    my $branch_id = $branch_rs->branch_id;
    return(
        nav          => $self->_get_nav($branch_rs->stem),
        stem_id      => $branch_rs->stem->stem_id,
        branch_id    => $branch_id,
        title        => $branch_rs->title,
        nodes        => \@nodes,
    );
}

sub node_add {
    my $self = shift;
    my %args = @_;

    my $branch_id = $args{branch_id};
    my $weight    = $self->schema
                         ->resultset('Node')
                         ->search({branch_id => $branch_id})
                         ->get_column('weight')
                         ->max;

    my $node_rs = $self->schema->resultset('Node')->create({
        branch_id => $branch_id,
        title     => $args{title},
        weight    => ++$weight,
    });

    return(
        nav     => $self->_get_nav($node_rs->branch->stem),
        stem_id => $node_rs->branch->stem->stem_id,
        node_id => $node_rs->node_id,
        title   => $node_rs->title,
        leaves  => [ ],
    );
}

sub node_view {
    my $self = shift;
    my $node_rs = $self->schema->resultset('Node')->single({node_id => shift});

    my @leaves;
    my $leaves_rs = $node_rs->leaves;
    while (my $leaf_rs = $leaves_rs->next) {
        push @leaves, {
            leaf_id => $leaf_rs->leaf_id,
            content => $leaf_rs->content
        };
    }

    return(
        nav     => $self->_get_nav($node_rs->branch->stem),
        stem_id => $node_rs->branch->stem->stem_id,
        node_id => $node_rs->node_id,
        title   => $node_rs->title,
        leaves  => \@leaves,
    );
}

sub node_update_order {
    my $self = shift;
    my %args = @_;

    my $node_id    = $args{node_id}   // die 'no node_id';
    my $old_index  = $args{old_index} // die 'no old_index';
    my $new_index  = $args{new_index} // die 'no new_index';

    my $leaf_rs = _get_leaf_by_weight($self, $old_index, $node_id) || die 'Unable to locate leaf';

    my $guard = $self->schema->txn_scope_guard;

    my $i = $new_index;
    if($new_index > $old_index) {
        # ascending
        while($i > $old_index) {
            my $sib_leaf_rs = _get_leaf_by_weight($self, $i--, $node_id) || next;
            $sib_leaf_rs->update({weight => $i});
        }
    }
    else {
        # descending
        while($i < $old_index) {
            my $sib_leaf_rs = _get_leaf_by_weight($self, $i++, $node_id) || next;
            $sib_leaf_rs->update({weight => $i});
        }

    }

    $leaf_rs->update({weight => $new_index});

    $guard->commit;

    return 1;
}

sub _get_leaf_by_weight {
    my ($self, $weight, $node_id) = @_;
    $self->schema->resultset('Leaf')->single({
        node_id => $node_id,
        weight  => $weight,
    });
}

sub leaf_add {
    my $self = shift;
    my %args = @_;

    my $node_id = $args{node_id};
    my $weight  = $self->schema
                       ->resultset('Leaf')
                       ->search({node_id => $node_id})
                       ->get_column('weight')
                       ->max;

    my $leaf_rs = $self->schema->resultset('Leaf')->create({
        node_id => $node_id,
        content => $args{content},
        weight  => ++$weight,
    });

    return(
        nav     => $self->_get_nav($leaf_rs->node->branch->stem),
        stem_id => $leaf_rs->node->branch->stem->stem_id,
        leaf_id => $leaf_rs->leaf_id,
        content => $leaf_rs->content,
        tags    => [ ],
    );
}

sub leaf_view {
    my $self = shift;

    my $leaf_rs = $self->schema->resultset('Leaf')->single({leaf_id => shift});

    my @tag_names;
    my $tags = $leaf_rs->tags;
    while (my $tag = $tags->next) {
        push @tag_names, $tag->tag->name;
    }

    return(
        nav     => $self->_get_nav($leaf_rs->node->branch->stem),
        stem_id => $leaf_rs->node->branch->stem->stem_id,
        leaf_id => $leaf_rs->leaf_id,
        content => $leaf_rs->content,
        tags    => \@tag_names,
    );
}

sub tag_view {
    my $self = shift;
    my $id_or_name  = shift;

    my $field  = ($id_or_name =~ m/^\d+$/) ? 'tag_id' : 'name';
    my $tag_rs = $self->schema->resultset('Tag')->single({$field => $id_or_name});

    my @leaves;
    my $tag_leaves = $tag_rs->tag_leaves;
    while (my $tag_leaf_rs = $tag_leaves->next) {
        push @leaves, {$self->leaf_view($tag_leaf_rs->leaf->leaf_id)};
    }

    return(
        nav     => $self->_get_nav,
        tag_id  => $tag_rs->tag_id,
        name    => $tag_rs->name,
        leaves  => \@leaves,
    );
}

sub tag_add {
    my $self = shift;
    my %args = @_;

    my $tag_rs = $self->schema->resultset('Tag')->find_or_create({
        name => $args{'name'},
    });

    my $tag_leaf_rs = $self->schema->resultset('TagLeaf')->find_or_create({
        tag_id  => $tag_rs->tag_id,
        leaf_id => $args{leaf_id},
    });

    return(
        nav     => $self->_get_nav,
        leaf_id => $tag_leaf_rs->leaf_id,
        tag_id  => $tag_leaf_rs->tag_id,
    );
}


1;
