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

Lavoco::Website - Framework to run a tiny website, controlled by a JSON config file and Template::Toolkit.

=head1 VERSION

Version 0.06

=cut

our $VERSION = '0.06';

$VERSION = eval $VERSION;

=head1 SYNOPSIS

Runs a FastCGI web-app for serving Template::Toolkit templates.

This module is purely a personal project to control various small websites, use at your own risk.

 #!/usr/bin/env perl
 
 use strict;
 use warnings;
 
 use Lavoco::Website;
 
 my $website = Lavoco::Website->new( name => 'Example' );
 
 my $action = lc( $ARGV[0] );   # (start|stop|restart)
 
 $website->$action;

A JSON config file (named F<website.json> by default) should be placed in the base directory of your website.

 {
    "title":"The Example Website",
    "pages" : [
       {
          "url" : "/",
          "template":"index.tt",
          "label" : "Home",
          "title" : "Your online guide to the example website"
       },
 
    ...
 }

The mandetory field in the config is C<pages>, as an array of JSON objects.

Each C<page> object should have a C<url> and C<template> as a bare minimum.

All other fields are up to you, to fit your requirements.

When a request is made, a lookup is done for a matching C<url>, and that C<page> is then selected.

The C<page> object is available in your template.

It is useful to have pages within a page.

When a page is selected that is a sub-page, an extra key for C<parents> is included in the C<page> object as a list of the parent pages.

This is useful for building breadcrumb links.

=cut

=head1 METHODS

=head2 Class Methods

=head3 new

Creates a new instance of the website object.

=head2 Instance Methods

=cut

has name       => ( is => 'rw', isa => 'Str',  default => 'Website' );
has base       => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_base' );
has dev        => ( is => 'rw', isa => 'Bool', lazy => 1, builder => '_build_dev' );
has processes  => ( is => 'rw', isa => 'Int',  default => 5 );
has _pid       => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build__pid' );
has _socket    => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build__socket' );
has templates  => ( is => 'rw', isa => 'Str',  lazy => 1, builder => '_build_templates' );

sub _build_base
{
    return $Bin;
}

sub _build_dev
{
    my $self = shift;

    return 0 if $self->base =~ m:/live:;

    return 1;
}

sub _build__pid
{
    my $self = shift;

    return $self->base . '/website.pid';
}

sub _build__socket
{
    my $self = shift;

    return $self->base . '/website.sock';
}

sub _build_templates
{
    my $self = shift;

    return $self->base . '/templates';
}

=head3 name

The identifier for the website, used as the process title.

=head3 base

The base directory of the application, we use L<FindBin> for this.

=head3 dev

Flag to indicate whether this we're running a development instance of the website.

It's on by default, and only turned off if the base directory contains C</live>.

I typically use C</home/user/www.example.com/dev> and C</home/user/www.example.com/live>.

=head3 processes

Number of FastCGI process to spawn, 5 by default.

=head3 templates

The directory containing the TT templates, by default it's C<$website-E<gt>base . '/templates'>.

=head3 start

Starts the FastCGI daemon.

=cut

sub stop
{
    my $self = shift;

    print "Stopping pidfile if it exists...\n";

    if ( ! -e $self->_pid )
    {
        print "PID file doesn't exist...\n";
        
        return $self;
    }
    
    open( my $fh, "<", $self->_pid ) or die "Cannot open pidfile: $!";

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

    if ( -e $self->_pid )
    {
        print "PID file " . $self->_pid . " already exists, I think you should kill that first, or specify a new pid file with the -p option\n";
        
        return $self;
    }

    print "Building FastCGI engine...\n";
    
    my $server = Plack::Handler::FCGI->new(
        nproc      =>   $self->processes,
        listen     => [ $self->_socket ],
        pid        =>   $self->_pid,
        detach     =>   1,
        proc_title =>   $self->name,
    );
    
    $server->run( $self->_handler );
}

=head3 restart

Restarts the FastCGI daemon, with a 1 second delay between stopping and starting.

=cut

sub restart
{
    my $self = shift;
    
    $self->stop;

    sleep 1;

    $self->start;

    return $self;
}

# returns a code-ref for the FCGI handler/server.

sub _handler
{
    my $self = shift;

    return sub {

        ##############
        # initialise #
        ##############

        my $req = Plack::Request->new( shift );

        my %stash = (
            website  => $self,
            req      => $req,
            now      => DateTime->now,
            started  => join( '.', gettimeofday ),
        );

        my $log = Log::AutoDump->new( base_dir => $stash{ website }->base . '/logs', filename => 'website.log' );

        $log->debug("Started");

        ##################
        # get the config #
        ##################

        $stash{ config } = $stash{ website }->_get_config( log => $log );


#        write_file( $stash{ filename }, { binmode => ':utf8' }, to_json( $stash{ config }, { utf8 => 1, pretty => 1 } ) );

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

        #########################################################################
        # find a matching 'page' from the config that matches the requested url #
        #########################################################################

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

                        $stash{ page }->{ parents } = [];
                        
                        push @{ $stash{ page }->{ parents } }, $each_page;
                        
                        last;
                    }
                }
            }
        }

        $log->debug( "Matching page found in config" ) if exists $stash{ page };

        ############################################
        # translate the path to a content template #
        ############################################

        if ( $stash{ page } )
        {
            $log->debug( "Template for page: " . $stash{ page }->{ template } );

            $stash{ content } = 'content' . $path . '.tt';

            $log->debug( "Trying content template: " . $stash{ content } );

            if ( ! -e $stash{ website }->base . '/templates/' . $stash{ content } )
            {
                $log->debug( "File not found: " . $stash{ website }->base . '/templates/' . $stash{ content } );

                $stash{ content } = 'content' . $path . ( $path =~ m:/$: ? '' : '/' ) . 'index.tt';

                $log->debug( "Trying content template: " . $stash{ content } );

                if ( ! -e $stash{ website }->base . '/templates/' . $stash{ content } )
                {
                    $log->debug( "File not found: " . $stash{ website }->base . '/templates/' . $stash{ content } );

                    $log->debug( "Apparently no content needed" );

                    delete $stash{ content };
                }
            }
        }

        #######
        # 404 #
        #######
        
        if ( ! exists $stash{ page } )
        {
            $stash{ page } = { template => '404.tt' };

            $stash{ website }->_send_email(
                from      => $stash{ config }->{ send_alerts_from },
                to        => $stash{ config }->{ send_404_alerts_to },
                subject   => "404 - " . $path,
                text_body => "404 - " . $path . "\n\nReferrer: " . ( $req->referer || 'None' ) . "\n\n" . Dumper( $req ) . "\n\n" . Dumper( \%ENV ),
            );

            $res->status( 404 );
        }
        else
        {
            $res->status( 200 );
        }

        my $tt = Template->new( ENCODING => 'UTF-8', INCLUDE_PATH => $stash{ website }->templates );

        $log->debug("Processing template: " . $stash{ website }->templates . "/" . $stash{ page }->{ template } );

        my $body = '';

        $tt->process( $stash{ page }->{ template }, \%stash, \$body ) or $log->debug( $tt->error );

        $res->content_type('text/html; charset=utf-8');

        $res->body( encode( "UTF-8", $body ) );

        $stash{ took } = join( '.', gettimeofday ) - $stash{ started };
        
        $log->debug( "The stash contains...", \%stash );
        
        $log->debug( "Took " . sprintf("%.5f", $stash{ took } ) . " seconds");

        #######################################
        # cleanup (circular references, etc.) #
        #######################################

        delete $stash{ page }->{ parent } if exists $stash{ page };

        return $res->finalize;
    }
}

sub _get_config
{
    my ( $self, %args ) = @_;

    my $log = $args{ log };    

    my $filename = $self->base . '/website.json';

    $log->debug( "Opening config file: " . $filename );

    my $string = read_file( $filename, { binmode => ':utf8' } );

    my $config = undef;

    eval {
        $config = decode_json $string;
    };

    $log->debug( $@ ) if $@;

    return $config;
}

sub _send_email
{
    my ( $self, %args ) = @_;

    if ( $args{ to } )
    {
        Email::Stuffer->from( $args{ from } )
            ->to( $args{ to } )
            ->subject( $args{ subject } )
            ->text_body( $args{ text_body } )
            ->send;
    }

    return $self;
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

