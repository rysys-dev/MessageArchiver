use imessage_database::tables::{handle::Handle, table::Cacheable};
use serde::Serialize;

use crate::{
    emit::{EngineError, Output, done},
    source::Source,
};

#[derive(Serialize)]
struct HandleLine {
    handle_id: i32,
    handle: String,
    service: Option<String>,
    country: Option<String>,
    person_centric_id: Option<String>,
    /// Handles with the same `person` are one person to Messages (imessage-database's dedupe).
    /// The app merges further with Contacts.
    person: Option<i32>,
}

pub fn run(source: &Source, out: &mut Output) -> Result<(), EngineError> {
    let people = Handle::dedupe(&Handle::cache(&source.db)?);
    let mut stmt = source.db.prepare(
        "SELECT ROWID, id, service, country, person_centric_id FROM handle ORDER BY ROWID",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(HandleLine {
            handle_id: r.get(0)?,
            handle: r.get(1)?,
            service: r.get(2)?,
            country: r.get(3)?,
            person_centric_id: r.get(4)?,
            person: None,
        })
    })?;
    let mut count = 0;
    for row in rows {
        let mut line = row?;
        line.person = people.get(&line.handle_id).copied();
        out.line(&line)?;
        count += 1;
    }
    done(count);
    Ok(())
}
