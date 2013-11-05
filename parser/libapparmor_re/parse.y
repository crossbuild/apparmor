/*
 * (C) 2006, 2007 Andreas Gruenbacher <agruen@suse.de>
 * Copyright (c) 2003-2008 Novell, Inc. (All rights reserved)
 * Copyright 2009-2010 Canonical Ltd.
 *
 * The libapparmor library is licensed under the terms of the GNU
 * Lesser General Public License, version 2.1. Please see the file
 * COPYING.LGPL.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *
 * Parsing of regular expression into expression trees as implemented in
 * expr-tree
 */

%{
/* #define DEBUG_TREE */
#include "expr-tree.h"

%}

%union {
	char c;
	Node *node;
	Chars *cset;
}

%{

void regex_error(Node **, const char *, const char *);
#define YYLEX_PARAM &text
int regex_lex(YYSTYPE *, const char **);

static inline Chars *insert_char(Chars* cset, uchar a)
{
	cset->insert(a);
	return cset;
}

static inline Chars* insert_char_range(Chars* cset, uchar a, uchar b)
{
	if (a > b)
		swap(a, b);
	for (uchar i = a; i <= b; i++)
		cset->insert(i);
	return cset;
}

%}

%pure-parser
/* %error-verbose */
%lex-param {YYLEX_PARAM}
%parse-param {Node **root}
%parse-param {const char *text}
%name-prefix = "regex_"

%token <c> CHAR
%type <c> regex_char cset_char1 cset_char cset_charN
%type <cset> charset cset_chars
%type <node> regex expr terms0 terms qterm term

/**
 * Note: destroy all nodes upon failure, but *not* the start symbol once
 * parsing succeeds!
 */
%destructor { $$->release(); } expr terms0 terms qterm term

%%

/* FIXME: Does not parse "[--]", "[---]", "[^^-x]". I don't actually know
          which precise grammer Perl regexs use, and rediscovering that
	  is proving to be painful. */

regex	    : /* empty */	{ *root = $$ = &epsnode; }
	    | expr		{ *root = $$ = $1; }
	    ;

expr	    : terms
	    | expr '|' terms0	{ $$ = new AltNode($1, $3); }
	    | '|' terms0	{ $$ = new AltNode(&epsnode, $2); }
	    ;

terms0	    : /* empty */	{ $$ = &epsnode; }
	    | terms
	    ;

terms	    : qterm
	    | terms qterm	{ $$ = new CatNode($1, $2); }
	    ;

qterm	    : term
	    | term '*'		{ $$ = new StarNode($1); }
	    | term '+'		{ $$ = new PlusNode($1); }
	    ;

term	    : '.'		{ $$ = new AnyCharNode; }
	    | regex_char	{ $$ = new CharNode($1); }
	    | '[' charset ']'	{ $$ = new CharSetNode(*$2);
				  delete $2; }
	    | '[' '^' charset ']'
				{ $$ = new NotCharSetNode(*$3);
				  delete $3; }
	    | '[' '^' '^' cset_chars ']'
				{ $4->insert('^');
				  $$ = new NotCharSetNode(*$4);
				  delete $4; }
	    | '(' regex ')'	{ $$ = $2; }
	    ;

regex_char  : CHAR
	    | '^'		{ $$ = '^'; }
	    | '-'		{ $$ = '-'; }
	    | ']'		{ $$ = ']'; }
	    ;

charset	    : cset_char1 cset_chars
				{ $$ = insert_char($2, $1); }
	    | cset_char1 '-' cset_charN cset_chars
				{ $$ = insert_char_range($4, $1, $3); }
	    ;

cset_chars  : /* nothing */	{ $$ = new Chars; }
	    | cset_chars cset_charN
				{ $$ = insert_char($1, $2); }
	    | cset_chars cset_charN '-' cset_charN
				{ $$ = insert_char_range($1, $2, $4); }
	    ;

cset_char1  : cset_char
	    | ']'		{ $$ = ']'; }
	    | '-'		{ $$ = '-'; }
	    ;

cset_charN  : cset_char
	    | '^'		{ $$ = '^'; }
	    ;

cset_char   : CHAR
	    | '['		{ $$ = '['; }
	    | '*'		{ $$ = '*'; }
	    | '+'		{ $$ = '+'; }
	    | '.'		{ $$ = '.'; }
	    | '|'		{ $$ = '|'; }
	    | '('		{ $$ = '('; }
	    | ')'		{ $$ = ')'; }
	    ;

%%


int octdigit(char c)
{
	if (c >= '0' && c <= '7')
		return c - '0';
	return -1;
}

int hexdigit(char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	else if (c >= 'A' && c <= 'F')
		return 10 + c - 'A';
	else if (c >= 'a' && c <= 'f')
		return 10 + c - 'a';
	else
		return -1;
}

int regex_lex(YYSTYPE *val, const char **pos)
{
	int c;

	val->c = **pos;
	switch(*(*pos)++) {
	case '\0':
		(*pos)--;
		return 0;

	case '*': case '+': case '.': case '|': case '^': case '-':
	case '[': case ']': case '(' : case ')':
		return *(*pos - 1);

	case '\\':
		val->c = **pos;
		switch(*(*pos)++) {
		case '\0':
			(*pos)--;
			/* fall through */
		case '\\':
			val->c = '\\';
			break;

		case '0':
			val->c = 0;
			if ((c = octdigit(**pos)) >= 0) {
				val->c = c;
				(*pos)++;
			}
			if ((c = octdigit(**pos)) >= 0) {
				val->c = (val->c << 3) + c;
				(*pos)++;
			}
			if ((c = octdigit(**pos)) >= 0) {
				val->c = (val->c << 3) + c;
				(*pos)++;
			}
			break;

		case 'x':
			val->c = 0;
			if ((c = hexdigit(**pos)) >= 0) {
				val->c = c;
				(*pos)++;
			}
			if ((c = hexdigit(**pos)) >= 0) {
				val->c = (val->c << 4) + c;
				(*pos)++;
			}
			break;

		case 'a':
			val->c = '\a';
			break;

		case 'e':
			val->c = 033  /* ESC */;
			break;

		case 'f':
			val->c = '\f';
			break;

		case 'n':
			val->c = '\n';
			break;

		case 'r':
			val->c = '\r';
			break;

		case 't':
			val->c = '\t';
			break;
		}
	}
	return CHAR;
}

void regex_error(Node ** __attribute__((unused)),
		 const char *text __attribute__((unused)),
		 const char *error __attribute__((unused)))
{
	/* We don't want the library to print error messages. */
}
