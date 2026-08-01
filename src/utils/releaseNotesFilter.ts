import type {
  ReleaseNoteArchiveGroup,
  ReleaseNoteChangeType,
} from "@/data/releaseNotes";

export function normalizeReleaseNotesSearch(value: string) {
  return String(value ?? "")
    .trim()
    .toLocaleLowerCase("de-DE")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

export function filterReleaseNotesArchive(
  archive: ReleaseNoteArchiveGroup[],
  query: string,
  selectedTypes: Set<ReleaseNoteChangeType>,
) {
  const normalizedQuery = normalizeReleaseNotesSearch(query);

  return archive.flatMap((group) => {
    const normalizedDate = normalizeReleaseNotesSearch(group.dateLabel);
    const entries = group.entries.filter((entry) => {
      const typeMatches = selectedTypes.size === 0 || selectedTypes.has(entry.type);
      const queryMatches =
        !normalizedQuery
        || normalizedDate.includes(normalizedQuery)
        || normalizeReleaseNotesSearch(entry.title).includes(normalizedQuery);
      return typeMatches && queryMatches;
    });

    return entries.length ? [{ ...group, entries }] : [];
  });
}
