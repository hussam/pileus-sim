{application, pileus,
 [
  {description, "Pileus simulation"},
  {vsn, "1"},
  {registered, []},
  {modules, [
               phofs,
               exp,
               oracle,
               server,
               client
            ]},
  {applications, [
                  kernel,
                  stdlib
                 ]},
  {env, []}
 ]}.
