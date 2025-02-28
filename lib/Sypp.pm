# Copyright (C) 2024 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package Sypp;
use Mojo::Base -base;

use Data::Dumper;
use Cwd qw(abs_path);
use File::Basename;
use File::Path qw( mkpath );
use Carp ();

use solv;

use Mojo::Log;
use Mojo::UserAgent;

use Sypp::Repo;
use Sypp::Repo::Rpm;
use Sypp::Repo::System;

has repos     => sub { [] };
has repodirs  => sub { Carp::croak 'repodirs are required' };
has cachedir  => './cache/';

has pool      => sub { solv::Pool->new };
has sysrepo   => sub { Carp::croak 'sysrepo is not initialized' };

has concurrency => 4;
has log       => sub { Mojo::Log->new };
has dumper    => sub { Carp::croak 'dumper is required if debug is enabled' };
has force     => 0;
has debug     => 0;
has verbosity => 0;

has version   => '';

sub refresh {
    my $self = shift;
    $self->refresh_repos;
    $self->repos || die 'No repos defined';
    $self->refresh_pool;
    $self->pool || die 'Cannot init seolv::pool';
}

sub refresh_repos {
    my $self = shift;
    my @repos;
    my @reposdirs = @{$self->repodirs};
    $self->log->error($self->dumper('PLUGIN::REPO', 'reposdirs', \@reposdirs)) if $self->debug;

    my $repo;
    for my $reposdir (@reposdirs) {
        next unless -d $reposdir;
        my $dir;
        next unless opendir($dir, $reposdir);
        for my $reponame (sort(grep {/\.repo$/} readdir($dir))) {
            my $cfg = new Config::IniFiles('-file' => "$reposdir/$reponame");
            $self->app->log->error($self->dumper('PLUGIN::REPO', 'cfg', $cfg)) if $self->debug;
            for my $alias ($cfg->Sections()) {
                my $repoattr = {'alias' => $alias, 'enabled' => 0, 'priority' => 99, 'autorefresh' => 1, 'type' => 'rpm-md', 'metadata_expire' => 900};
                for my $p ($cfg->Parameters($alias)) {
                    $repoattr->{$p} = $cfg->val($alias, $p);
                }
                $repo = undef;
                if ($repoattr->{type} eq 'rpm-md') {
                    $repo = Sypp::Repo::Rpm->new($alias, 'repomd', $repoattr);
                }
                next unless $repo;
                $repo->cacheroot($self->cachedir);
                $repo->verbosity($self->verbosity);
                for my $mirrorsfile ("$reposdir/$alias.mirrors", $self->cachedir . "/$alias.mirrors") {
                    my @oldmirrors = @{$repo->mirrors};
                    my @moremirrors;
                    if (-r $mirrorsfile) {
                        if (open(my $fh, '<', $mirrorsfile)) {
                            while(my $line = <$fh>) {
                                chomp $line;
                                push @moremirrors, $line;
                            }
                        } else {
                            print STDERR "Warning: couldn't open $mirrorsfile; ignoring it.";
                        }
                    }
                    @{$repo->mirrors} = (@moremirrors, @oldmirrors) if @moremirrors;
                }
                push @repos, $repo;
            }
        }
    }
    if ($repo && $repo->cacherootmeta) {
        -d $repo->cacherootmeta or mkpath($repo->cacherootmeta) or print STDERR "WRN: Couldn't create path: " . $repo->cacherootmeta . "\n";
    }
    $self->log->error($self->dumper('PLUGIN::REPO', '@repos', \@repos)) if $self->debug;
    @{$self->repos} = @repos;

    my $sysrepo = Sypp::Repo::System->new('@System', 'system');
    $sysrepo->cacheroot($self->cachedir);
    $self->sysrepo($sysrepo);
}

sub _load_stub {
  my ($repodata) = @_;
  my $repo = $repodata->{repo}->{appdata};
  return $repo ? $repo->load_ext($repodata) : 0;
}

sub refresh_pool {
    my $self = shift;
    my $pool = $self->pool;
    $pool->setarch();
    # $pool->set_loadcallback(\&_load_stub); do not load filelists for now because they are too heavy
    $self->sysrepo->load($pool);
    my $concurrency = $self->concurrency;
    my @allgood = (1);
    my @repos = @{$self->repos};
    my $current = 0;
    print STDERR "Refreshing repos with concurrency $concurrency\n" if $self->verbosity > 1;
    my $retry = 0;
    my $ua = Mojo::UserAgent->new->connect_timeout(3)->request_timeout(10)->max_redirects(6);
    for (my $i = 0; $i < $concurrency; $i++) {
        my $repo;
        my @urls;
        # do not do concurrency for all repos that are cached or disabled
        while(1) {
            $repo = shift @repos;
            last if !$repo;
            print STDERR "Repo: " . ($repo->alias // 'unnamed') . "; enabled: " . ($repo->enabled // 'no') .  "\n" if $self->verbosity > 1;
            next if !$repo->enabled;
            $repo->{handle} = $pool->add_repo($repo->{alias});
            $repo->{handle}->{appdata} = $repo;
            $repo->{handle}->{priority} = 99 - ($repo->{priority} // 0);
            # first try to load from cache
            next if Sypp::Repo::load($repo, $pool, $self->force);
            print "\n";
            STDOUT->flush();
            @urls = @{$repo->mirrors};
            last;
        }
        last unless $repo;

        my ($next_repomd,  $then_repomd,  $catch);
        my ($next_primary, $wrap1, $wrap, $catch_primary);
        $current++;
        my $url;
        my $ii = $i;
        my $cachedir = $self->cachedir;

        $next_repomd = sub {
            unless ($repo && @allgood) {
                $current--;
                Mojo::IOLoop->stop unless ($current);
                return;
            }
            $url = shift @urls;
            unless ($url) {
                print STDERR "[CRI] No more mirrors to try downloading repodata from " . $repo->alias . "\n";
                shift @allgood;
                return Mojo::IOLoop->reset;
            }
            $url = $url . '/repodata/repomd.xml';
            print STDERR "[I$ii] trying $url\n" if $self->verbosity;
            return $ua->get_p($url)->then($then_repomd, $catch);
        };

        $then_repomd = sub {
            my $tx = shift;
            my $code = $tx->res->code // 0;
            print STDERR "[I$ii] ($code) from " . $tx->req->url . "\n" if $repo->verbosity;
            return $next_repomd->() unless $code == 200;

            my $dest = $cachedir . '/meta/' . ($repo->alias // 'noalias') . '/repomd.xml';
            eval {
                my $destdir = dirname($dest);
                -d $destdir || mkpath($destdir) || die "Cannot create path {$destdir}";
                $tx->res->content->asset->move_to($dest);
                open(my $f, '<', $dest) or do {
                    print STDERR "[WRN$ii] Error opening metadata file: $dest\n";
                    shift @allgood;
                    return Mojo::IOLoop->reset;
                };
                my $xf = solv::xfopen_fd($dest, fileno($f));
                $repo->{cookie} = $repo->calc_cookie_fp($xf);
                $repo->{handle}->add_repomdxml($xf, 0);
                @urls = @{$repo->mirrors};
                $next_primary->();
            } or do {
                print STDERR "[CRI] Cannot save $dest: $@\n";
                shift @allgood;
                return Mojo::IOLoop->reset;
            };
        };

        $next_primary = sub {
            my $baseurl = shift @urls;
            return unless $repo && $repo->{handle} && $baseurl;
            my ($filename1, $filechksum1) = $repo->find('primary');
            my ($filename2, $filechksum2) = $repo->find('unpdateinfo') if $filename1;
            my ($p_primary, $p_update, $p_meta);
            unless ($filename2) {
                $p_primary = $ua->get_p( $baseurl . '/' . $filename1)->then($wrap1, $catch_primary)->then($wrap, $catch_primary);
            } else {
                $p_primary = $ua->get_p( $baseurl . '/' . $filename1)->then($wrap1);
                $p_update  = $ua->get_p( $baseurl . '/' . $filename2)->then($wrap1);
                $p_meta = Mojo::Promise->all($p_primary, $p_update)->then($wrap, $catch_primary);
            }
        };

        $wrap1 = sub {
            my $tx = shift;
            my $code = $tx->res->code // 0;
            print STDERR "[I] loading primary ($code)\n" if $self->verbosity > 2;
            return $next_primary->() unless $code == 200;
            my $filename = Mojo::File->new($tx->req->url)->basename;
            my $dest = $cachedir . '/meta/' . ($repo->alias // 'noalias') . '/' . $filename;
            eval {
                my $destdir = dirname($dest);
                -d $destdir || mkpath($destdir) || die "Cannot create path {$destdir}";
                $tx->res->content->asset->move_to($dest);
                open(my $f, '<', $dest) or do {
                    print STDERR "[WRN$ii] Error opening metadata file: $dest\n";
                    shift @allgood;
                    return Mojo::IOLoop->reset;
                };
                my $xf = solv::xfopen_fd($dest, fileno($f));
                $repo->{handle}->add_rpmmd($xf, undef, 0)  if $dest =~ /primary.xml.+/;
                $repo->{handle}->add_updateinfoxml($xf, 0) if $dest =~ /updateinfo.xml.+/;
                1;
            } or do {
                print STDERR "[CRI] Cannot save $dest: $@\n";
                shift @allgood;
                return Mojo::IOLoop->reset;
            };
        };
        $wrap = sub {
            print STDERR "[I$ii] wrapping up\n" if $self->verbosity > 2;
            return unless $repo;
            $repo->add_exts();
            $repo->writecachedrepo();
            $repo->{handle}->create_stubs();
            $repo->refresh_mirrors; # TODO this can be async as well
            print STDERR "[I$ii] " . $repo->alias . " loaded\n";
            while(1) {
                $repo = shift @repos;
                last if !$repo;
                next if !$repo->enabled;
                $repo->{handle} = $pool->add_repo($repo->{alias});
                $repo->{handle}->{appdata} = $repo;
                $repo->{handle}->{priority} = 99 - ($repo->{priority} // 0);
                # first try to load from cache
                next if Sypp::Repo::load($repo, $pool, $self->force);
                print "\n";
                STDOUT->flush();
                @urls = @{$repo->mirrors};
                last;
            }
            return $next_repomd->();
        };

        $catch_primary = sub {
            my $err = shift // '<mpty>';
            my $reponame = '<unknown>';
            $reponame = $repo->alias if $repo && $repo->alias;
            print STDERR "[WRN] error {$err} refreshing repo $reponame\n" if @allgood;
            $next_primary->();
        };

        $catch = sub {
            my $err = shift // '<mpty>';
            print STDERR "[WRN] error {$err} from $url\n" if $self->verbosity && @allgood;
            $next_repomd->();
        };

        $next_repomd->();
    }
    Mojo::IOLoop->start;
    Carp::croak "[INF] Critical error detected. Aborting\n" unless @allgood;
    $pool->addfileprovides();
    $pool->createwhatprovides();
    $pool->set_namespaceproviders($solv::NAMESPACE_LANGUAGE, $pool->Dep('de'), 1);
}

sub install {
    my ($self, @args) = @_;
    Carp::croak "Sypp::install is not implemented";
    1;
}

sub download {
    my ($self, @args) = @_;
    my $flags = $solv::Selection::SELECTION_NAME | $solv::Selection::SELECTION_PROVIDES | $solv::Selection::SELECTION_GLOB;
    $flags |= $solv::Selection::SELECTION_CANON | $solv::Selection::SELECTION_DOTARCH | $solv::Selection::SELECTION_REL;
    my $pool = $self->pool;
    my @jobs;
    for my $arg (@args) {
        print STDERR "ARG: $arg\n\n";
        my $sel = $pool->select($arg, $flags);
        die("nothing matches '$arg'\n") if $sel->isempty();
        push @jobs, $sel->jobs($solv::Job::SOLVER_INSTALL);
    };
    unless (@jobs) {
        my $sel = $pool->Selection_all();
        my $exit_code=system('grep opensuse-tumbleweed /etc/os-release');
        if ($exit_code) {
            print STDERR "will do update\n";
            push @jobs, $sel->jobs($solv::Job::SOLVER_UPDATE);
        } else {
            print STDERR "will do dist-upgrade\n";
            push @jobs, $sel->jobs($solv::Job::SOLVER_DISTUPGRADE);
        }
    }
    my $solver = $pool->Solver();
    $solver->set_flag($solv::Solver::SOLVER_FLAG_SPLITPROVIDES, 1);
    $solver->set_flag($solv::Solver::SOLVER_FLAG_DUP_ALLOW_VENDORCHANGE, 0);
    while (1) {
        my @problems = $solver->solve(\@jobs);
        last unless @problems;
        for my $problem (@problems) {
            print "Problem $problem->{id}/".@problems.":\n";
            print $problem->str()."\n";
            my @solutions = $problem->solutions();
            for my $solution (@solutions) {
                print "  Solution $solution->{id}:\n";
                for my $element ($solution->elements(1)) {
                    print "  - ".$element->str()."\n";
                }
                print "\n";
            }
            my $sol;
            while (1) {
                print "Please choose a solution: ";
                $sol = <STDIN>;
                chomp $sol;
                last if $sol eq 's' || $sol eq 'q' || ($sol =~ /^\d+$/ && $sol >= 1 && $sol <= @solutions);
            }
            next if $sol eq 's';
            exit(1) if $sol eq 'q';
            my $solution = $solutions[$sol - 1];
            for my $element ($solution->elements()) {
                my $newjob = $element->Job();
                if ($element->{type} == $solv::Solver::SOLVER_SOLUTION_JOB) {
                    $jobs[$element->{jobidx}] = $newjob;
                } else {
                    push @jobs, $newjob if $newjob && !grep {$_ == $newjob} @jobs;
                }
            }
        }
    }
    my $trans = $solver->transaction();
    undef $solver;
    if ($trans->isempty()) {
        print "Nothing to do.\n";
        exit 0;
    }
    print "\nTransaction summary:\n\n";
    for my $c ($trans->classify($solv::Transaction::SOLVER_TRANSACTION_SHOW_OBSOLETES|$solv::Transaction::SOLVER_TRANSACTION_OBSOLETE_IS_UPGRADE)) {
        if ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_ERASE) {
            print "$c->{count} packages to erase:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_INSTALL) {
            print "$c->{count} packages to install:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_REINSTALLED) {
            print "$c->{count} packages to reinstall:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_DOWNGRADED) {
            print "$c->{count} packages to downgrade:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_CHANGED) {
            print "$c->{count} packages to change:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_UPGRADED) {
            print "$c->{count} packages to upgrade:\n";
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_VENDORCHANGE) {
            printf "$c->{count} to change vendor from '%s' to '%s':\n", $c->{fromstr}, $c->{tostr};
        } elsif ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_ARCHCHANGE) {
            printf "$c->{count} to change arch from '%s' to '%s':\n", $c->{fromstr}, $c->{tostr};
        } else {
            next;
        }
        for my $p ($c->solvables()) {
            if ($c->{type} == $solv::Transaction::SOLVER_TRANSACTION_UPGRADED || $c->{type} == $solv::Transaction::SOLVER_TRANSACTION_DOWNGRADED) {
                my $other = $trans->othersolvable($p);
                printf "  - %s -> %s\n", $p->str(), $other->str();
            } else {
                printf "  - %s\n", $p->str();
            }
        }
        print "\n";
    }
    printf "install size change: %d K\n\n", $trans->calc_installsizechange();

    my @newpkgs = $trans->newsolvables();
    my %newpkgsfps;
    my @allgood = (1);
    if (@newpkgs) {
        my $downloadsize = 0;
        $downloadsize += $_->lookup_num($solv::SOLVABLE_DOWNLOADSIZE) for @newpkgs;
        my $concurrency = $self->concurrency;
        my $current = 0;
        printf "Downloading %d packages, %d K. Concurrency: %d\n", scalar(@newpkgs), $downloadsize / 1024, $concurrency;
        for (my $i = 0; $i < $concurrency; $i++){
            my $p = shift @newpkgs;
            next unless $p;
            my $repo = $p->{repo}->{appdata};
            my @urls = @{$repo->mirrors};
            my $url = shift @urls;
            my ($location) = $p->lookup_location();
            $url = $url . '/' . $location;
            my $ua = Mojo::UserAgent->new->request_timeout(300)->connect_timeout(4)->max_redirects(10);
            my ($next, $then, $catch);
            my $started = time();
            $current++;
            my $ii = $i;
            $next = sub {
                unless ($p && @allgood) {
                    $current--;
                    Mojo::IOLoop->stop unless $current;
                    return;
                }
                $url = shift @urls;
                unless ($url) {
                    print STDERR "[CRI] Couldn't download $location from " . $repo->alias . "\n";
                    shift @allgood;
                    return Mojo::IOLoop->reset;
                }
                $url = $url . '/' . $location;
                $started = time();
                print STDERR "[I$ii] trying $url\n" if $self->verbosity;
                return $ua->get_p($url)->then($then, $catch);
            };

            $then = sub {
                my $tx = shift;
                my $elapsed = int(1000*(time() - $started));
                my $code = $tx->res->code // 0;
                print STDERR "[I$ii] ($code) from " . $tx->req->url . "\n" if $self->verbosity;
                if ($code == 200) {
                    my $dest = $self->cachedir . '/packages/' . ($repo->alias // 'noalias') . '/' . $location;
                    eval {
                        my $destdir = dirname($dest);
                        -d $destdir || mkpath($destdir) || die "Cannot create path {$destdir}";
                        $tx->res->content->asset->move_to($dest);
                        1;
                    } or do {
                        print STDERR "[CRI] Cannot save $dest: $@\n";
                        shift @allgood;
                        return Mojo::IOLoop->reset;
                    };

                    $p = shift @newpkgs;
                    if ($p) {
                        $repo = $p->{repo}->{appdata};
                        @urls = @{$repo->mirrors};
                        ($location) = $p->lookup_location();
                    }
                }
                $next->();
            };

            $catch = sub {
                my $err = shift // '<mpty>';
                my $elapsed = int(1000*(time() - $started));
                print STDERR "[WRN] error {$err} from $url\n" if $self->verbosity && @allgood;
                $next->();
            };

            print STDERR "[I$ii] trying $url\n" if $self->verbosity;
            $ua->get_p($url)->then($then, $catch);
        };
        print "Starting poll\n" if $self->verbosity;
        STDOUT->flush();
        Mojo::IOLoop->start;
        Carp::croak "[INF] Critical error detected. Aborting\n" unless @allgood;
        print "\n";
    }
    print "Use rpm to finish operation (at own risk!):\n\n";
    $trans->order();
    my $needi = 0;
    for my $p ($trans->steps()) {
        my $steptype = $trans->steptype($p, $solv::Transaction::SOLVER_TRANSACTION_RPM_ONLY);
        if ($steptype == $solv::Transaction::SOLVER_TRANSACTION_ERASE) {
            my $evr = $p->{evr};
            $evr =~ s/^[0-9]+://;	# strip epoch
            system('echo', 'rpm', '-e', '--nodeps', "$p->{name}-$evr.$p->{arch}");
        } elsif ($steptype == $solv::Transaction::SOLVER_TRANSACTION_INSTALL || $steptype == $solv::Transaction::SOLVER_TRANSACTION_MULTIINSTALL) {
            $needi = 1;
        }
    }
    system('echo', 'rpm', '-iUv', '--force', $self->cachedir . "/packages/*/*/*rpm") if $needi;
}

sub list {
    my @res;
    for my $r (@{shift->repos}) {
        my $name    = $r->name;
        my $alias   = $r->alias;
        my $baseurl = $r->baseurl;

        my %repo = ( name => $name, alias => $alias, baseurl => $baseurl );
        push @res, \%repo;
    }
    return \@res;
}

1;
