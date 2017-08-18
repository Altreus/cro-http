use Cro;
use Cro::HTTP::BodyParser;
use Cro::HTTP::BodyParserSelector;
use Cro::HTTP::BodySerializer;
use Cro::HTTP::BodySerializerSelector;
use Cro::HTTP::Request;
use Cro::HTTP::Response;
use IO::Path::ChildSecure;
use Cro::HTTP::MimeTypes;

class X::Cro::HTTP::Router::OnlyInHandler is Exception {
    has $.what;
    method message() {
        "Can only use '$!what' inside of a request handler"
    }
}
class X::Cro::HTTP::Router::NoRequestBodyMatch is Exception {
    method message() {
        "None of the request-body matches could handle the body (this exception " ~
        "type is typically caught and handled by Cro to produce a 400 Bad Request " ~
        "error; if you're seeing it, you may have an over-general error handling)"
    }
}

module Cro::HTTP::Router {
    role Query {}
    multi trait_mod:<is>(Parameter:D $param, :$query! --> Nil) is export {
        $param does Query;
    }
    role Header {}
    multi trait_mod:<is>(Parameter:D $param, :$header! --> Nil) is export {
        $param does Header;
    }
    role Cookie {}
    multi trait_mod:<is>(Parameter:D $param, :$cookie! --> Nil) is export {
        $param does Cookie;
    }

    class RouteSet does Cro::Transform {
        my class Handler {
            has Str $.method;
            has &.implementation;
        }

        has Handler @!handlers;
        has $!path-matcher;
        has Cro::HTTP::BodyParser @!body-parsers;
        has Cro::HTTP::BodySerializer @!body-serializers;

        method consumes() { Cro::HTTP::Request }
        method produces() { Cro::HTTP::Response }

        method transformer(Supply:D $requests) {
            supply {
                whenever $requests -> $req {
                    my $*CRO-ROUTER-REQUEST = $req;
                    my $*WRONG-METHOD = False;
                    my $*MISSING-UNPACK = False;
                    my @*BIND-FAILS;
                    with $req.path ~~ $!path-matcher {
                        if @!body-parsers {
                            $req.body-parser-selector = Cro::HTTP::BodyParserSelector::Prepend.new(
                                parsers => @!body-parsers,
                                next => $req.body-parser-selector
                            );
                        }
                        my $*CRO-ROUTER-RESPONSE := Cro::HTTP::Response.new(request => $req);
                        if @!body-serializers {
                            $*CRO-ROUTER-RESPONSE.body-serializer-selector =
                                Cro::HTTP::BodySerializerSelector::Prepend.new(
                                    serializers => @!body-serializers,
                                    next => $req.body-serializer-selector
                                );
                        }
                        my ($handler-idx, $arg-capture) = .ast;
                        my $handler := @!handlers[$handler-idx];
                        my &implementation := $handler.implementation;
                        my $response = $*CRO-ROUTER-RESPONSE;
                        whenever start ($req.path eq '/' ??
                                        implementation() !!
                                        implementation(|$arg-capture)) {
                            emit $response;

                            QUIT {
                                when X::Cro::HTTP::Router::NoRequestBodyMatch {
                                    $response.status = 400;
                                    emit $response;
                                }
                                when X::Cro::HTTP::BodyParserSelector::NoneApplicable {
                                    $response.status = 400;
                                    emit $response;
                                }
                                default {
                                    .note;
                                    $response.status = 500;
                                    emit $response;
                                }
                            }
                        }
                    }
                    else {
                        my $status = 404;
                        if $*WRONG-METHOD {
                            $status = 405;
                        }
                        elsif $*MISSING-UNPACK {
                            $status = 400;
                        }
                        elsif @*BIND-FAILS {
                            for @*BIND-FAILS -> $imp, \cap {
                                $imp(|cap);
                                CATCH {
                                    when X::TypeCheck::Binding::Parameter {
                                        if .parameter.named {
                                            $status = 400;
                                            last;
                                        }
                                    }
                                    default {}
                                }
                            }
                        }
                        emit Cro::HTTP::Response.new(:$status, request => $*CRO-ROUTER-REQUEST);
                    }
                }
            }
        }

        method add-handler(Str $method, &implementation --> Nil) {
            @!handlers.push(Handler.new(:$method, :&implementation));
        }

        method add-body-parser(Cro::HTTP::BodyParser $parser --> Nil) {
            @!body-parsers.push($parser);
        }

        method add-body-serializer(Cro::HTTP::BodySerializer $serializer --> Nil) {
            @!body-serializers.push($serializer);
        }

        method definition-complete(--> Nil) {
            my @route-matchers;

            my @handlers = @!handlers; # This is closed over in the EVAL'd regex
            for @handlers.kv -> $index, $handler {
                # Things we need to do to prepare segments for binding and unpack
                # request data.
                my @checks;
                my @make-tasks;
                my @types = int8, int16, int32, int64, uint8, uint16, uint32, uint64;

                # If we need a signature bind test (due to subset/where).
                my $need-sig-bind = False;

                # Positionals are URL segments, nameds are unpacks of other
                # request data.
                my $signature = $handler.implementation.signature;
                my (:@positional, :@named) := $signature.params.classify:
                    { .named ?? 'named' !! 'positional' };

                # Compile segments definition into a matcher.
                my @segments-required;
                my @segments-optional;
                my $segments-terminal = '';

                sub match-types($type,
                                :$lookup, :$target-name,
                                :$seg-index, :@matcher-target, :@constraints) {
                    for @types {
                        if $type === $_ {
                            if $lookup {
                                pack-range($type.^nativesize, !$type.^unsigned,
                                           target => $lookup, :$target-name);
                            } else {
                                pack-range($type.^nativesize, !$type.^unsigned,
                                           :$seg-index, :@matcher-target, :@constraints);
                            }
                            return True;
                        }
                    }
                    False;
                }

                sub pack-range($bits, $signed,
                               :$target, :$target-name, # named
                               :$seg-index, :@matcher-target, :@constraints) {
                    my $bound = 2 ** ($bits - 1);

                    if $target.defined && $target-name.defined {
                        push @checks, '(with ' ~ $target ~ ' { ' ~
                                               ( if $signed {
                                                       -$bound ~ ' <= $_ <= ' ~ $bound - 1
                                                   } else {
                                                     '0 <= $_ <= ' ~ 2 ** $bits - 1
                                                 }
                                               )
                                               ~ '|| !($*MISSING-UNPACK = True)'
                                               ~ ' } else { True })';
                        # we coerce to Int here for two reasons:
                        # * Str cannot be coerced to native types;
                        # * We already did a range check;
                        @make-tasks.push: '%unpacks{Q[' ~ $target-name ~ ']} = .Int with ' ~ $target;
                    } else {
                        my Str $range = $signed ?? -$bound ~ ' <= $_ <= ' ~ $bound - 1 !! '0 <= $_ <= ' ~ 2 ** $bits - 1;
                        my Str $check = '<?{('
                                      ~ Q:c/with @segs[{$seg-index}]/
                                      ~ ' {( '~ $range
                                      ~ ' )} else { True }) }>';
                        @matcher-target.push: Q['-'?\d+:] ~ $check;
                        @make-tasks.push: Q:c/.=Int with @segs[{$seg-index}]/;
                        $need-sig-bind = True if @constraints;
                    }
                }

                for @positional.kv -> $seg-index, $param {
                    if $param.slurpy {
                        $segments-terminal = '{} .*:';
                    }
                    else {
                        my @matcher-target := $param.optional
                            ?? @segments-optional
                            !! @segments-required;
                        my $type := $param.type;
                        my @constraints = extract-constraints($param);
                        if $type =:= Mu || $type =:= Any || $type =:= Str {
                            if @constraints == 1 && @constraints[0] ~~ Str:D {
                                # Literal string constraint; matches literally.
                                @matcher-target.push("'@constraints[0]'");
                            }
                            else {
                                # Any match will do, but need bind check.
                                @matcher-target.push('<-[/]>+:');
                                $need-sig-bind = True;
                            }
                        }
                        elsif $type =:= Int || $type =:= UInt {
                            @matcher-target.push(Q['-'?\d+:]);
                            my Str $coerce-prefix = $type =:= Int ?? '.=Int' !! '.=UInt';
                            @make-tasks.push: $coerce-prefix ~ Q:c/ with @segs[{$seg-index}]/;
                            $need-sig-bind = True if @constraints;
                        }
                        else {
                            my $matched = match-types($type, :$seg-index,
                                                      :@matcher-target, :@constraints);
                            die "Parameter type $type.^name() not allowed on a request unpack parameter" unless $matched;
                        }
                    }
                }
                my $segment-matcher = " '/' " ~
                    @segments-required.join(" '/' ") ~
                    @segments-optional.map({ "[ '/' $_ " }).join ~ (' ]? ' x @segments-optional) ~
                    $segments-terminal;

                # Turned nameds into unpacks.
                for @named -> $param {
                    my $target-name = $param.named_names[0];
                    my ($exists, $lookup) = do given $param {
                        when Cookie {
                            '$req.has-cookie(Q[' ~ $target-name ~ '])',
                            '$req.cookie-value(Q[' ~ $target-name ~ '])'
                        }
                        when Header {
                            '$req.has-header(Q[' ~ $target-name ~ '])',
                            '$req.header(Q[' ~ $target-name ~ '])'
                        }
                        default {
                            '$req.query-hash{Q[' ~ $target-name ~ ']}:exists',
                            '$req.query-value(Q[' ~ $target-name ~ '])'
                        }
                    }
                    unless $param.optional {
                        push @checks, '(' ~ $exists ~ ' || !($*MISSING-UNPACK = True))';
                    }

                    my $type := $param.type;
                    if $type =:= Mu || $type =:= Any || $type =:= Str {
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $_ with ' ~ $lookup;
                    }
                    elsif $type =:= Int || $type =:= UInt {
                        push @checks, '(with ' ~ $lookup ~ ' { so /^"-"?\d+$/ } else { True })';
                        push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = ' ~
                                                        ($type =:= Int ?? '.Int' !! '.UInt')
                                                        ~ ' with ' ~ $lookup;
                    }
                    elsif $type =:= Positional {
                        given $param {
                            when Header {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.headers';
                            }
                            when Cookie {
                                die "Cookies cannot be extracted to List. Maybe you want '%' instead of '@'";
                            }
                            default {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.query-hash.List';
                            }
                        }
                    }
                    elsif $type =:= Associative {
                        given $param {
                            when Cookie {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.cookie-hash';
                            }
                            when Header {
                                push @make-tasks,
                                'my %result;'
                                    ~ '$req.headers.map({ %result{$_.name} = $_.value });'
                                    ~ '%unpacks{Q['
                                    ~ $target-name
                                    ~ ']} = %result;';
                            }
                            default {
                                push @make-tasks, '%unpacks{Q[' ~ $target-name ~ ']} = $req.query-hash'
                            }
                        }
                    }
                    else {
                        my $matched = match-types($type, :$lookup, :$target-name);
                        die "Parameter type $type.^name() not allowed on a request unpack parameter" unless $matched;
                    }
                    $need-sig-bind = True if extract-constraints($param);
                }

                my $method-check = '<?{ $req.method eq "' ~ $handler.method ~
                    '" || !($*WRONG-METHOD = True) }>';
                my $checks = @checks
                    ?? '<?{ ' ~ @checks.join(' and ') ~ ' }>'
                    !! '';
                my $form-cap = '{ my %unpacks; ' ~ @make-tasks.join(';') ~
                    '; $cap = Capture.new(:list(@segs), :hash(%unpacks)); }';
                my $bind-check = $need-sig-bind
                    ?? '<?{ my $imp = @handlers[' ~ $index ~ '].implementation; ' ~
                            '$imp.signature.ACCEPTS($cap) || ' ~
                            '!(@*BIND-FAILS.push($imp, $cap)) }>'
                    !! '';
                my $make = '{ make (' ~ $index ~ ', $cap) }';
                push @route-matchers, join " ",
                    $segment-matcher, $method-check, $checks, $form-cap,
                    $bind-check, $make;
            }

            use MONKEY-SEE-NO-EVAL;
            push @route-matchers, '<!>';
            $!path-matcher = EVAL 'regex { ^ ' ~
                ':my $req = $*CRO-ROUTER-REQUEST; ' ~
                ':my @segs = $req.path-segments; ' ~
                ':my $cap; ' ~
                '[ '  ~ @route-matchers.join(' | ') ~ ' ] ' ~
                '$ }';
        }
    }

    sub extract-constraints(Parameter:D $param) {
        my @constraints;
        sub extract($v --> Nil) { @constraints.push($v) }
        extract($param.constraints);
        return @constraints;
    }

    sub route(&route-definition) is export {
        my $*CRO-ROUTE-SET = RouteSet.new;
        route-definition();
        $*CRO-ROUTE-SET.definition-complete();
        return $*CRO-ROUTE-SET;
    }

    sub get(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('GET', &handler);
    }

    sub post(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('POST', &handler);
    }

    sub put(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('PUT', &handler);
    }

    sub delete(&handler --> Nil) is export {
        $*CRO-ROUTE-SET.add-handler('DELETE', &handler);
    }

    sub body-parser(Cro::HTTP::BodyParser $parser --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-parser($parser);
    }

    sub body-serializer(Cro::HTTP::BodySerializer $serializer --> Nil) is export {
        $*CRO-ROUTE-SET.add-body-serializer($serializer);
    }

    sub term:<request>() is export {
        $*CRO-ROUTER-REQUEST //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<request>)
    }

    sub term:<response>() is export {
        $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<response>)
    }

    sub request-body-blob(**@handlers) is export {
        run-body-handler(@handlers, await request.body-blob)
    }

    sub request-body-text(**@handlers) is export {
        run-body-handler(@handlers, await request.body-text)
    }

    sub request-body(**@handlers) is export {
        run-body-handler(@handlers, await request.body)
    }

    sub run-body-handler(@handlers, \body) {
        for @handlers {
            when Block {
                return .(body) if .signature.ACCEPTS(\(body));
            }
            when Pair {
                with request.content-type -> $content-type {
                    if .key eq $content-type.type-and-subtype {
                        return .value()(body) if .value.signature.ACCEPTS(\(body));
                    }
                }
            }
            default {
                die "request-body handlers can only be a Block or a Pair, not a $_.^name()";
            }
        }
        die X::Cro::HTTP::Router::NoRequestBodyMatch.new;
    }

    proto header(|) is export {*}
    multi header(Cro::HTTP::Header $header --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($header);
    }
    multi header(Str $header --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($header);
    }
    multi header(Str $name, Str(Cool) $value --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<header>);
        $resp.append-header($name, $value);
    }

    proto content(|) is export {*}
    multi content(Str $content-type, $body, :$enc = $body ~~ Str ?? 'utf-8' !! Nil --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status //= 200;
        with $enc {
            $resp.append-header('Content-type', qq[$content-type; charset=$_]);
        }
        else {
            $resp.append-header('Content-type', $content-type);
        }
        $resp.set-body($body);
    }

    proto created(|) is export {*}
    multi created(Str() $location --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status = 201;
        $resp.append-header('Location', $location);
    }
    multi created(Str() $location, $content-type, $body, *%options --> Nil) {
        created $location;
        content $content-type, $body, |%options;
    }

    proto redirect(|) is export {*}
    multi redirect(Str() $location, :$temporary, :$permanent, :$see-other --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        if $permanent {
            $resp.status = 308;
        }
        elsif $see-other {
            $resp.status = 303;
        }
        else {
            $resp.status = 307;
        }
        $resp.append-header('Location', $location);
    }
    multi redirect(Str() $location, $content-type, $body, :$temporary,
                   :$permanent, :$see-other, *%options --> Nil) {
        redirect $location, :$permanent, :$see-other;
        content $content-type, $body, |%options;
    }

    proto not-found(|) is export {*}
    multi not-found(--> Nil) {
        set-status(404);
    }
    multi not-found($content-type, $body, *%options --> Nil) {
        set-status(404);
        content $content-type, $body, |%options;
    }

    proto bad-request(|) is export {*}
    multi bad-request(--> Nil) {
        set-status(400);
    }
    multi bad-request($content-type, $body, *%options --> Nil) {
        set-status(400);
        content $content-type, $body, |%options;
    }

    proto forbidden(|) is export {*}
    multi forbidden(--> Nil) {
        set-status(403);
    }
    multi forbidden($content-type, $body, *%options --> Nil) {
        set-status(403);
        content $content-type, $body, |%options;
    }

    proto conflict(|) is export {*}
    multi conflict(--> Nil) {
        set-status(409);
    }
    multi conflict($content-type, $body, *%options --> Nil) {
        set-status(409);
        content $content-type, $body, |%options;
    }

    sub set-cookie($name, $value, *%opts) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        $resp.set-cookie($name, $value, |%opts);
    }

    sub set-status(Int $status --> Nil) {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<content>);
        $resp.status = $status;
    }

    sub cache-control(:$public, :$private, :$no-cache, :$no-store,
                      Int :$max-age, Int :$s-maxage,
                      :$must-revalidate, :$proxy-revalidate,
                      :$no-transform) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        $resp.remove-header('Cache-Control');
        die if ($public, $private, $no-cache).grep(Bool).elems != 1;
        my @headers = (:$public, :$private, :$no-cache, :$no-store,
                       :$max-age, :$s-maxage,
                       :$must-revalidate, :$proxy-revalidate,
                       :$no-transform);
        my $cache = @headers.map(
            {
                if .key eq 'max-age'|'s-maxage' { "{.key}={.value}" if .value }
                else { "{.key}" if .value }
            }).join(', ');
        $resp.append-header('Cache-Control', $cache);
    }

    sub static(Str $base, @path?, :$mime-types) is export {
        my $resp = $*CRO-ROUTER-RESPONSE //
            die X::Cro::HTTP::Router::OnlyInHandler.new(:what<route>);
        my $child = '.';
        for @path {
            $child = $child.IO.add: $_;
        }

        my %fallback = $mime-types // {};
        my $ext = $child eq '.' ?? $base.IO.extension !! $child.IO.extension;
        my $content-type = %mime{$ext} // %fallback{$ext} // 'application/octet-stream';

        my sub get_or_404($path) {
            if $path.IO.e {
                content $content-type, slurp($path, :bin);
            } else {
                $resp.status = 404;
            }
        }

        if $child eq '.' {
            get_or_404($base);
        } else {
            with $base.IO.&child-secure: $child {
                get_or_404($_);
            } else {
                $resp.status = 403;
            }
        }
    }
}
