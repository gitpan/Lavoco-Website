package Lavoco::Website;

use 5.006;


use Moose;

use Data::Dumper;
use DateTime;
use Email::Stuffer;
use Encode;
use File::Slurp;
use FindBin qw($Bin);
use JSON;
use Log::AutoDump;
use Plack::Handler::FCGI;
use Plack::Request;
use Template;
use Time::HiRes qw(gettimeofday);

$Data::Dumper::Sortkeys = 1;

=head1 NAME

Lavoco::Website - Framework to run a tiny website, controlled by a json config file and Template::Toolkit.

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

$VERSION = eval $VERSION;

=head1 SYNOPSIS

Runs a FastCGI web-app for serving Template::Toolkit templates.

 #!/usr/bin/env perl
 
 use strict;
 use warnings;
 
 use lib 'lib';
 
 use Lavoco::Website;
 
 my $website = Lavoco::Website->new( name => 'Organic' );
 
 $website->stop if $ARGV[0] =~ /(stop|restart)/i;
 
 sleep 1 if $ARGV[0] =~ /restart/i;
 
 $website->start if $ARGV[0] =~ /(start|restart)/i;

=cut

=head1 METHODS

=head2 Class Methods

=head3 new

Creates a new instance of the website object.

=head2 Instance Methods

=cut

has name      => ( is => 'rw', isa => 'Str',  default => 'Website' );
has dev       => ( is => 'rw', isa => 'Bool', lazy => 1, builder => '_build_dev' );
has processes => ( is => 'rw', isa => 'Int',  default => 5 );
has base      => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_base' );
has pid       => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_pid' );
has socket    => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_socket' );
has templates => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_templates' );

sub _build_dev
{
    my $self = shift;

    return 0 if $self->base =~ m:/live:;

    return 1;
}

sub _build_base
{
    return $Bin;
}

sub _build_pid
{
    my $self = shift;

    return $self->base . '/' . lc( $self->name ) . '.pid';
}

sub _build_socket
{
    my $self = shift;

    return $self->base . '/' . lc( $self->name ) . '.sock';
}

sub _build_templates
{
    my $self = shift;

    return $self->base . '/templates';
}

=head3 name

The identifier for the website, used as the process title.

=cut


=head3 start

Starts the FastCGI daemon.

=cut

sub stop
{
    my $self = shift;

    print "Stopping pidfile if it exists...\n";

    if ( ! -e $self->pid )
    {
        print "PID file doesn't exist...\n";
        
        return;
    }
    
    open( my $fh, "<", $self->pid ) or die "Cannot open pidfile: $!";

    my @pids = <$fh>;

    close $fh;

    chomp( $pids[0] );

    print "Killing pid $pids[0] ...\n"; 

    kill 15, $pids[0];

    return $self;
}

=head3 stop

Stops the FastCGI daemon.

=cut

sub start
{
    my $self = shift;

    if ( -e $self->pid )
    {
        print "PID file " . $self->pid . " already exists, I think you should kill that first, or specify a new pid file with the -p option\n";
        
        return $self;
    }

    print "Building FastCGI engine...\n";
    
    my $server = Plack::Handler::FCGI->new(
        nproc      =>   $self->processes,
        listen     => [ $self->socket ],
        pid        =>   $self->pid,
        detach     =>   1,
        proc_title =>   $self->name,
    );
    
    $server->run( $self->_handler );
}





sub _handler
{
    my $self = shift;

    return sub {

        ##############
        # initialise #
        ##############

        my $req = Plack::Request->new( shift );

        my $log = Log::AutoDump->new( base_dir => $self->base . '/logs', filename => lc( $self->name ) . '.log' );

        $log->debug("Started");

        my %stash = (
            website  => $self,
            req      => $req,
            now      => DateTime->now,
            start    => join( '.', gettimeofday ),
            filename => $self->base . '/config.json',
        );

        ############################
        # get the config from json #
        ############################

        $log->debug( "Opening config file: " . $stash{ filename } );

        my $string = read_file( $stash{ filename }, { binmode => ':utf8' } );

        $stash{ config } = decode_json $string;



    #    write_file( $stash{ filename }, { binmode => ':utf8' }, to_json( $stash{ config }, { utf8 => 1, pretty => 1 } ) );


        my $path = $req->uri->path;

        $log->debug( "Requested path: " . $path ); 

        my $res = $req->new_response;

        ###############
        # sitemap xml #
        ###############

        if ( $path eq '/sitemap.xml' )
        {
            my $base = ($req->env->{'psgi.url_scheme'} || "http") .
                "://" . ($req->env->{HTTP_HOST} || (($req->env->{SERVER_NAME} || "") . ":" . ($req->env->{SERVER_PORT} || 80)));

            my $sitemap = '<?xml version="1.0" encoding="UTF-8"?>';

            $sitemap .= "\n";

            $sitemap .= '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.sitemaps.org/schemas/sitemap/0.9 http://www.sitemaps.org/schemas/sitemap/0.9/sitemap.xsd">';

            $sitemap .= "\n";

            foreach my $each_page ( @{ $stash{ config }->{ pages } } )
            {
                $sitemap .= "<url><loc>" . $base . $each_page->{ url } . "</loc></url>\n";

                if ( ref $each_page->{ pages } eq 'ARRAY' )
                {
                    foreach my $each_sub_page ( @{ $each_page->{ pages } } )
                    {
                        $sitemap .= "<url><loc>" . $base . $each_sub_page->{ url } . "</loc></url>\n";        
                    }
                }
            }
            
            $sitemap .= "</urlset>\n";

            $res->status(200);

            $res->content_type('application/xml; charset=utf-8');
            
            $res->body( encode( "UTF-8", $sitemap ) );

            return $res->finalize;
        }

        #########
        # pages #
        #########

        if ( $path eq '/' )
        {
            $stash{ template } = 'index.tt';
        }
        elsif ( $path =~ m:^/post: )
        {
            $stash{ template } = 'post.tt';
        }
        elsif ( $path =~ m:^/page: )
        {
            $stash{ template } = 'page.tt';
        }
        elsif ( $path =~ m:^/category: )
        {
            $stash{ template } = 'category.tt';
        }
        elsif ( $path =~ m:^/archives: )
        {
            $stash{ template } = 'archives.tt';
        }
        elsif ( $path =~ m:^/fullwidth: )
        {
            $stash{ template } = 'fullwidth.tt';
        }
        elsif ( $path =~ m:^/contact: )
        {
            $stash{ template } = 'contact.tt';
        }


        foreach my $each_page ( @{ $stash{ config }->{ pages } } )
        {
            if ( $path eq $each_page->{ url } )
            {
                $stash{ page } = $each_page;
                last;
            }

            if ( ref $each_page->{ pages } eq 'ARRAY' )
            {
                foreach my $each_sub_page ( @{ $each_page->{ pages } } )
                {
                    if ( $path eq $each_sub_page->{ url } )
                    {
                        $stash{ page } = $each_sub_page;
                        last;
                    }
                }
            }
        }


        ################################################
        # translate the path to a template and content #
        ################################################

        my @parts = split( '/', $path );

        shift @parts;   # first element is always empty 

        push @parts, 'index' if scalar @parts == 1;

        $log->debug( "Path parts are...", \@parts );

        if ( $parts[ 0 ] =~ /^(organic|products|store|news)$/ )
        {
            $stash{ template } = $parts[ 0 ] . '.tt';

            $stash{ content } = $parts[ 0 ] . '/content/' . join( '/', @parts[ 1 ] ) . '.tt';

            $log->debug( "Content file is: " . $stash{ content } );

            if ( ! -e $self->base . '/templates/' . $stash{ content } )
            {
                $stash{ template } = '404.tt';
            }
        }

        $log->debug( "The stash contains...", \%stash );
        
        #######
        # 404 #
        #######
        
        if ( $stash{ template } eq '404.tt' )
        {
            if ( $stash{ config }->{ send_404_alerts_to } )
            {
                Email::Stuffer->from( $stash{ config }->{ send_alerts_from } )
                    ->to( $stash{ config }->{ send_404_alerts_to } )
                    ->subject( "404 - " . $path )
                    ->text_body( "404 - " . $path . "\n\nReferrer: " . ( $req->referer || 'None' ) . "\n\n" . Dumper( $req ) . "\n\n" . Dumper( \%ENV ) )
                    ->send;
            }

            $res->status( 404 );
        }
        else
        {
            $res->status( 200 );
        }

        my $tt = Template->new( ENCODING => 'UTF-8', INCLUDE_PATH => $self->templates );

        $log->debug("Using template file: " . $self->templates . "/" . $stash{ template } );

        my $body = '';

        $tt->process( $stash{ template }, \%stash, \$body ) or $log->debug( $tt->error );

        $res->content_type('text/html; charset=utf-8');

        $res->body( encode( "UTF-8", $body ) );

        $log->debug( "Took " . sprintf("%.5f", gettimeofday() - $stash{ start } ) . " seconds");

        return $res->finalize;
    }
}





=head1 TODO

More documentation.

=head1 AUTHOR

Rob Brown, C<< <rob at intelcompute.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-lavoco-website at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Lavoco-Website>.  I will be notified, and then you will
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Lavoco::Website


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Lavoco-Website>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Lavoco-Website>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Lavoco-Website>

=item * Search CPAN

L<http://search.cpan.org/dist/Lavoco-Website/>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2014 Rob Brown.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;

