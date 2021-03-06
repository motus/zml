%% Special handler for *html tags in zml
%%
%% Author: Joseph Wecker <joseph.wecker@gmail.com>
%%

-module(zml_special_html).

-export([process_tree/3]).

-include("special/zml_special_html.hrl").

-import(string, [to_lower/1, to_upper/1, join/2]).

% Each processor is run in order and returns an updated AST.  The fold function
% updates Attr and Children as per the new AST between each call so that if,
% for example, a sub-function removes some attributes from the special handler,
% it will be reflected in both the AST and the ID/Attr/Children on the next
% call.
process_tree({{"html", ID}, special, _Attr, _Children}, AST, Options) ->
  Transformations = [
    fun process_doctype/5,
    fun process_head_and_body/5,
    fun process_xhtml/5,
    fun process_metas/5,
    fun process_javascript/5,
    fun process_zss_and_images/5,
    fun process_autoclose/5,
    fun process_cleanup/5
  ],
  lists:foldl(
    fun(Transformer, NewAST) ->
      {_, _, NewAttr, NewChildren} = zml_util:get_tag(NewAST, [{"html",ID}]),
      Transformer(ID, NewAttr, NewChildren, NewAST, Options)
    end, AST, Transformations).

process_doctype(_ID, Attr, _Children, AST, _Options) ->
  [FirstLine | _] = AST,
  case is_list(FirstLine) of
    true ->
      case (string:sub_word(FirstLine,1) == "<!DOCTYPE") of
        true -> erlang:error("Please do not declare a DOCTYPE- use a " ++
            "'type' attribute on the *html tag instead.");
        false -> ok
      end;
    _ -> ok
  end,
  [Type] = zml_util:get_attr_vals_split(type, Attr, ?DEFAULT_TYPE),
  DoctypeString =
    case proplists:get_value(list_to_atom(Type), ?TYPES) of
      undefined ->
        Allowed = string:join(lists:map(
            fun atom_to_list/1,
            proplists:get_keys(?TYPES)),", "),
        erlang:error("'" ++ Type ++
          "' html type unknown. Try one of: " ++ Allowed);
      DS -> DS
    end,
  [DoctypeString | AST].

process_head_and_body(ID, Attr, Children, AST, _Options) ->
  % Ensure there is a body
  ExistingHead = zml_util:get_tag(Children, ["head"]),
  ExistingBody = zml_util:get_tag(Children, ["body"]),

  {Head, AllButHead} =
    case ExistingHead of
      undefined ->
        {zml_util:new_tag("head", normal, [], []), Children};
      _ ->
        {ExistingHead, zml_util:replace_tag(Children, ["head"], [])}
    end,
  Body =
    case ExistingBody of
      undefined ->
        zml_util:new_tag(body, normal, [], AllButHead);
      _ ->
        ExistingBody
    end,
  zml_util:update_tag(AST, {"html",ID}, special, Attr, [Head, Body]).

process_xhtml(ID, Attr, Children, AST, _Options) ->
  [[TypeFC | _]] = zml_util:get_attr_vals_split(type, Attr, ?DEFAULT_TYPE),
  case TypeFC == $x of
    false ->
      AST;
    true ->
      [Namespace] = zml_util:get_attr_vals_split(xmlns, Attr, ?XMLNS),
      [Language] = zml_util:get_attr_vals_split(
          "xml:lang", Attr, ?LANGUAGE_XML_DEFAULT),
      zml_util:update_tag(AST, {"html",ID}, special,
        [{"xmlns",[Namespace]}, {"xml:lang",[Language]} | Attr], Children)
      %% Skipping for now - xml declaration
      % TODO: flag to force insertion of the xml declaration
      %Encoding = get_html_attr(encoding, Attr, ?ENCODING_DEFAULT),
      %[?ENC_TOP_X(Encoding) | AST]
  end.

process_metas(ID, Attr, _Children, AST, _Options) ->
  [[Tp | _]] = zml_util:get_attr_vals_split(type, Attr, ?DEFAULT_TYPE),
  Metas = lists:foldr(fun(Input, Acc) -> new_metas(Input, Acc, Attr) end, [],
    [ {encoding,    Tp, ?ENCODING_DEFAULT},
      {language,    Tp, ?LANGUAGE_DEFAULT},
      {description, Tp, none},
      {keywords,    Tp, none},
      {copyright,   Tp, none},
      {nosmarttag,  Tp, true},
      {title,       Tp, none},
      {favicon,     Tp, none} ]),
  zml_util:append_children(AST, [{"html",ID},"head"], Metas).

process_zss_and_images(ID, Attr, Children, AST, Options) ->
  zs_html_zss_images:process(ID, Attr, Children, AST, Options).

process_javascript(ID, Attr, Children, AST, Options) ->
  zs_html_javascript:process(ID, Attr, Children, AST, Options).

process_cleanup(ID, Attr, Children, AST, _Options) ->
  CleanAttrs = lists:foldl(fun proplists:delete/2, Attr, ?SPECIAL_ATTRIBUTES),
  zml_util:update_tag(AST, {"html",ID}, special, CleanAttrs, Children).


new_metas({Name, Type, Def}, Acc, Attr) ->
  case zml_util:get_attr_vals_split(Name, Attr, Def) of
    ["none"] -> Acc;
    Vals -> metatag(Name, Type, Vals) ++ Acc
  end.

metatag(encoding, $x, [Val]) ->
  build_meta("http-equiv", "Content-Type",
             ["text/html;", "charset=" ++ to_upper(Val)], $x, false);

metatag(encoding, IsXml, [Val]) ->
  build_meta("http-equiv", "Content-Type",
             ["text/html;", "charset=" ++ Val], IsXml, $x);

metatag(language, IsXml, Vals) ->
  build_meta("http-equiv", "Content-Language", Vals, IsXml);

metatag(copyright, IsXml, Vals) ->
  build_meta(name, copyright, ["Copyright (c)" | Vals], IsXml, false);

metatag(nosmarttag, IsXml, _) ->
  build_meta(name, "MSSmartTagsPreventParsing", ["TRUE"], IsXml);

metatag(title, _, Vals) ->
  [zml_util:new_tag(title, [], zml_util:intersperse(Vals, " "))];

metatag(favicon, _, Vals) ->
  [zml_util:new_tag(link, [{"rel", ["icon"]}, {"href", Vals}], []),
   zml_util:new_tag(link, [{"rel", ["shortcut icon"]}, {"href", Vals}], [])];

metatag(Name, IsXml, Vals) -> build_meta(name, Name, Vals, IsXml).

build_meta(Key, Name, Vals, IsXml) ->
  build_meta(Key, Name, Vals, IsXml, IsXml).

build_meta(Key, Name, Vals, IsXml, LowerVals) ->
  NewName = case {Name, IsXml} of
    {"MSSmartTagsPreventParsing", $x} -> Name;
    {_, $x} -> to_lower(zml_util:str(Name));
    {_, _ } -> zml_util:str(Name)
  end,
  NewVals = case LowerVals of
    $x -> to_lower(join(Vals, " "));
    _  -> join(Vals, " ")
  end,
  [zml_util:new_tag(meta,
    [{zml_util:str(Key), [NewName]}, {"content", [NewVals]}], [])].


process_autoclose(_ID, Attr, _Children, AST, _Options) ->
  [[TypeFC|_]] = zml_util:get_attr_vals_split(type, Attr, ?DEFAULT_TYPE),
  autoclose(AST, TypeFC == $x, []).

autoclose([], _, Acc) -> lists:reverse(Acc);

autoclose([{Tag, Type, Attr, []} | T], IsXml, Acc) ->
  autoclose(T, IsXml, [{Tag, Type, Attr, close_tag(IsXml, Tag)} | Acc]);

autoclose([{Tag, Type, Attr, [newline]} | T], IsXml, Acc) ->
  autoclose(T, IsXml, [{Tag, Type, Attr, close_tag(IsXml, Tag)} | Acc]);

autoclose([{Tag, Type, Attr, Children} | T], IsXml, Acc) ->
  autoclose(T, IsXml,
    [{Tag, Type, Attr, autoclose(Children, IsXml, [])} | Acc]);

autoclose([H | T], IsXml, Acc) -> autoclose(T, IsXml, [H | Acc]).

close_tag(true, "meta" ) -> [];
close_tag(true, "img"  ) -> [];
close_tag(true, "link" ) -> [];
close_tag(true, "br"   ) -> [];
close_tag(true, "hr"   ) -> [];
close_tag(true, "input") -> [];
close_tag(true, "area" ) -> [];
close_tag(true, "param") -> [];
close_tag(true, "col"  ) -> [];
close_tag(true, "base" ) -> [];

close_tag(_, _) -> [""].

