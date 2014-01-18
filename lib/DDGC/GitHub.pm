package DDGC::GitHub;
# ABSTRACT: 

use Moose;
use Net::GitHub;
use DDGC::GitHub::Cmds;
use DateTime::Format::ISO8601;
use DateTime::Duration;
use HTTP::Request;
use JSON::MaybeXS;

has ddgc => (
  isa => 'DDGC',
  is => 'ro',
  weak_ref => 1,
  required => 1,
);

sub gh { DDGC::GitHub::Cmds->new($_[0]->net_github->args_to_pass) }

has net_github => (
  is => 'ro',
  lazy_build => 1,
);

sub _build_net_github {
  Net::GitHub->new( access_token => $_[0]->ddgc->config->github_token )
}

sub validate_session_code {
  my ( $self, $code, $user ) = @_;
  my $req = HTTP::Request->new('POST','https://github.com/login/oauth/access_token');
  $req->header('Content-type','application/json');
  $req->header('Accept','application/json');
  $req->content(JSON::MaybeXS->new->utf8(1)->encode({
    client_id => $self->ddgc->config->github_client_id,
    client_secret => $self->ddgc->config->github_client_secret,
    code => $code,
  }));
  my $response = $self->ddgc->http->request($req);
  my $result = JSON::MaybeXS->new->utf8(1)->decode($response->content);
  return undef unless defined $result->{access_token};
  my $net_github = $self->user_net_github($result->{access_token});
  my $gh_user = $self->update_user_from_data(scalar $net_github->user->show);
  my %scopes = map { $_ => 1 } split(",",$result->{scope});
  $gh_user->scope_public_repo($scopes{public_repo} ? 1 : 0);
  $gh_user->scope_user_email(
    $scopes{'user:email'}
      ? 1
      : $scopes{'user'}
        ? 1
        : 0
  );
  $gh_user->access_token($result->{access_token});
  $gh_user->users_id($user->id) if ($user);
  $gh_user->update;
  return $gh_user;
}

sub user_net_github {
  my ( $self, $access_token ) = @_;
  my $net_github = Net::GitHub->new( access_token => $access_token );
  my $gh = DDGC::GitHub::Cmds->new($net_github->args_to_pass);
  return wantarray
    ? ($net_github, $gh)
    : $net_github;
}

sub parse_datetime {
  $_[0]
    ? DateTime::Format::ISO8601->parse_datetime( $_[0] ) 
    : undef
}

sub datetime_str {
  $_[0]->strftime("%FT%TZ");
}

sub update_database {
  my ( $self ) = @_;
  $self->update_repos($self->ddgc->config->github_org,1);
}

sub find_or_update_user {
  my ( $self, $login ) = @_;
  my $user = $self->ddgc->rs('GitHub::User')->find({ login => $login });
  return $user if $user;
  return $self->update_user($login);
}

sub update_user {
  my ( $self, $login ) = @_;
  my $user = $self->gh->user($login);
  return $self->update_user_from_data($user);
}

sub update_user_from_data {
  my ( $self, $user ) = @_;
  return $self->ddgc->rs('GitHub::User')->update_or_create({
    github_id => $user->{id},
    (map { $_ => $user->{$_} } qw(
      login
      gravatar_id
      name
      company
      blog
      location
      email
      bio
      type
    )),
    (map { $_ => parse_datetime($user->{$_}) } qw(
      created_at
      updated_at
    )),
    gh_data => $user,
  },{
    key => 'github_user_github_id',
  });
}

sub update_repos {
  my ( $self, $login, $company ) = @_;
  my $owner = $self->update_user($login);
  my $gh = $self->gh;
  my @repos = $owner->type eq 'Organization'
    ? @{$gh->list_org($login)}
    : @{$gh->list_user($login)};
  while ($gh->has_next_page) {
    push @repos, @{$gh->next_page};
  }
  for (@repos) {
    $self->update_user_repo_from_data($owner,$_,$company);
  }
}

sub update_user_repo_from_data {
  my ( $self, $gh_user, $repo, $company ) = @_;
  my $gh_repo = $gh_user->update_or_create_related('github_repos',{
    github_id => $repo->{id},
    company_repo => $company ? 1 : 0,
    (map { $_ => $repo->{$_} } qw(
      forks_count
      full_name
      description
      watchers_count
      open_issues_count
    )),
    (map { $_ => parse_datetime($repo->{$_}) } qw(
      created_at
      updated_at
      pushed_at
    )),
    company_repo => $company ? 1 : 0,
    gh_data => $repo,
  },{
    key => 'github_repo_github_id',
  });
  $self->update_repo_commits($gh_repo);
  $self->update_repo_pulls($gh_repo);
  $self->update_repo_issues($gh_repo);
  return $gh_repo;
}

sub update_repo_pulls {
  my ( $self, $gh_repo ) = @_;
  return unless $gh_repo->pushed_at;
  my @gh_pulls;
  my $gh = $self->gh;
  my @pulls = @{$gh->pulls($gh_repo->owner_name,$gh_repo->repo_name)};
  for (@pulls) {
    push @gh_pulls, $self->update_repo_pull_from_data($gh_repo,$_);
  }
  while ($gh->has_next_page) {
    for (@{$gh->next_page}) {
      push @gh_pulls, $self->update_repo_pull_from_data($gh_repo,$_);
    }
  }
  return \@gh_pulls;
}

sub update_repo_pull_from_data {
  my ( $self, $gh_repo, $pull ) = @_;
  return $gh_repo->update_or_create_related('github_pulls',{
    github_id => $pull->{id},
    github_user_id => $self->find_or_update_user($pull->{user}->{login})->id,
    (map { $_ => $pull->{$_} } qw(
      title
      body
      state
    )),
    (map { $_ => parse_datetime($pull->{$_}) } qw(
      created_at
      updated_at
      closed_at
      merged_at
    )),
    gh_data => $pull,
  },{
    key => 'github_pull_github_id',
  });
}

sub update_repo_commits {
  my ( $self, $gh_repo ) = @_;
  return unless $gh_repo->pushed_at;
  my @gh_commits;
  my $latest = $gh_repo->search_related('github_commits',{},{
    rows => 1,
    order_by => { -desc => 'author_date' },
  })->first;
  my $gh = $self->gh;
  my @commits = $latest
    ? (@{$gh->commits_since(
      $gh_repo->owner_name,$gh_repo->repo_name,datetime_str(
        $latest->author_date + DateTime::Duration->new( seconds => 1 )
      )
    )})
    : (@{$gh->commits($gh_repo->owner_name,$gh_repo->repo_name)});
  for (@commits) {
    push @gh_commits, $self->update_repo_commit_from_data($gh_repo,$_);
  }
  while ($gh->has_next_page) {
    for (@{$gh->next_page}) {
      push @gh_commits, $self->update_repo_commit_from_data($gh_repo,$_);
    }
  }
  return \@gh_commits;
}

sub update_repo_commit_from_data {
  my ( $self, $gh_repo, $commit ) = @_;
  return $gh_repo->update_or_create_related('github_commits',{
    defined $commit->{author}
      ? ( github_user_id_author => $self->find_or_update_user($commit->{author}->{login})->id )
      : (),
    defined $commit->{committer}
      ? ( github_user_id_committer => $self->find_or_update_user($commit->{committer}->{login})->id )
      : (),
    author_date => parse_datetime($commit->{commit}->{author}->{date}),
    author_email => $commit->{commit}->{author}->{email},
    author_name => $commit->{commit}->{author}->{name},
    committer_date => parse_datetime($commit->{commit}->{committer}->{date}),
    committer_email => $commit->{commit}->{committer}->{email},
    committer_name => $commit->{commit}->{committer}->{name},
    sha => $commit->{sha},
    message => $commit->{message},
    gh_data => $commit,
  },{
    key => 'github_commit_sha_github_repo_id',
  });
}

sub update_repo_issues {
  my ( $self, $gh_repo ) = @_;
  my @gh_issues;
  my $latest = $gh_repo->search_related('github_issues',{},{
    rows => 1,
    order_by => { -desc => 'updated_at' },
  })->first;
  my $gh = $self->gh;
  my @issues = $latest
    ? (@{$gh->issues_since(
      $gh_repo->owner_name,$gh_repo->repo_name,datetime_str(
        $latest->updated_at + DateTime::Duration->new( seconds => 1 )
      )
    )})
    : (@{$gh->issues($gh_repo->owner_name,$gh_repo->repo_name)});
  for (@issues) {
    push @gh_issues, $self->update_repo_issue_from_data($gh_repo,$_);
  }
  while ($gh->has_next_page) {
    for (@{$gh->next_page}) {
      push @gh_issues, $self->update_repo_issue_from_data($gh_repo,$_);
    }
  }
  return \@gh_issues;
}

sub update_repo_issue_from_data {
  my ( $self, $gh_repo, $issue ) = @_;
  return $gh_repo->update_or_create_related('github_issues',{
    github_id => $issue->{id},
    github_user_id => $self->find_or_update_user($issue->{user}->{login})->id,
    (map { $_ => $issue->{$_} } qw(
      title
      body
      state
      comments
      number
    )),
    (map { $_ => parse_datetime($issue->{$_}) } qw(
      created_at
      updated_at
      closed_at
    )),
    defined $issue->{assignee}
      ? ( github_user_id_assignee => $self->find_or_update_user($issue->{assignee}->{login})->id )
      : (),
    gh_data => $issue,
  },{
    key => 'github_issue_github_id',
  });
}

1;
