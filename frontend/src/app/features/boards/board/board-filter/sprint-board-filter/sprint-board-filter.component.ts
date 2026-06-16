import {
  ChangeDetectionStrategy,
  ChangeDetectorRef,
  Component,
  ElementRef,
  HostListener,
  Input,
  OnInit,
} from '@angular/core';
import { UntilDestroyedMixin } from 'core-app/shared/helpers/angular/until-destroyed.mixin';
import {
  WorkPackageViewFiltersService,
} from 'core-app/features/work-packages/routing/wp-view-base/view-services/wp-view-filters.service';
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { CurrentProjectService } from 'core-app/core/current-project/current-project.service';
import { HalResource } from 'core-app/features/hal/resources/hal-resource';
import { CollectionResource } from 'core-app/features/hal/resources/collection-resource';
import { ApiV3FilterBuilder } from 'core-app/shared/helpers/api-v3/api-v3-filter-builder';
import { ApiV3ResourceCollection } from 'core-app/core/apiv3/paths/apiv3-resource';
import { ApiV3Resource } from 'core-app/core/apiv3/cache/cachable-apiv3-resource';
import { firstValueFrom, Observable } from 'rxjs';
import { take } from 'rxjs/operators';
import { Board } from 'core-app/features/boards/board/board';
import { QueryFilterInstanceResource } from 'core-app/features/hal/resources/query-filter-instance-resource';

const SPRINT_FILTER_KEY = 'sprint';

@Component({
  selector: 'op-sprint-board-filter',
  templateUrl: './sprint-board-filter.component.html',
  styleUrls: ['./sprint-board-filter.component.sass'],
  changeDetection: ChangeDetectionStrategy.OnPush,
  standalone: false,
})
export class SprintBoardFilterComponent extends UntilDestroyedMixin implements OnInit {
  @Input() board$:Observable<Board>;

  public isOpen = false;

  public sprints:HalResource[] = [];

  public sprintsLoading = false;

  public selectedId:string|null = null;

  public hasSprintsFeature = false;

  readonly text = {
    sprint: 'Sprint',
    allSprints: 'Todas as sprints',
    loading: '...',
    current: 'Atual',
    past: 'Passado',
    planned: 'Planejado',
  };

  constructor(
    readonly wpTableFilters:WorkPackageViewFiltersService,
    readonly apiV3Service:ApiV3Service,
    readonly currentProject:CurrentProjectService,
    readonly cdRef:ChangeDetectorRef,
    readonly elementRef:ElementRef,
  ) {
    super();
  }

  ngOnInit():void {
    this.wpTableFilters
      .pristine$()
      .pipe(take(1), this.untilDestroyed())
      .subscribe(() => {
        void this.loadSprintsAndAutoSelect();
      });
  }

  public get isActive():boolean {
    return this.selectedId !== null;
  }

  public get label():string {
    if (!this.isActive) return this.text.sprint;
    const found = this.sprints.find((s) => this.sprintId(s) === this.selectedId);
    return found ? (found.name as string) : this.text.sprint;
  }

  public isSelected(sprint:HalResource):boolean {
    return this.sprintId(sprint) === this.selectedId;
  }

  public statusLabel(sprint:HalResource):string {
    const href = ((sprint as Record<string, unknown>).status as { href?:string }|undefined)?.href ?? '';
    if (href.endsWith(':active')) return this.text.current;
    if (href.endsWith(':completed')) return this.text.past;
    return this.text.planned;
  }

  public isActiveSprint(sprint:HalResource):boolean {
    const href = ((sprint as Record<string, unknown>).status as { href?:string }|undefined)?.href ?? '';
    return href.endsWith(':active');
  }

  public select(sprint:HalResource):void {
    this.selectedId = this.sprintId(sprint);
    try {
      this.wpTableFilters.replace(SPRINT_FILTER_KEY, (filter:QueryFilterInstanceResource) => {
        filter.operator = filter.findOperator('=')!;
        filter.values = [sprint];
      });
    } catch {
      // sprint filter not available in schema — ignore
    }
    this.close();
  }

  public clearSprint():void {
    this.selectedId = null;
    this.wpTableFilters.remove(SPRINT_FILTER_KEY);
    this.close();
  }

  public toggleDropdown(event:MouseEvent):void {
    event.stopPropagation();
    if (this.isOpen) {
      this.close();
    } else {
      this.isOpen = true;
      this.cdRef.detectChanges();
    }
  }

  @HostListener('document:click', ['$event'])
  public onDocumentClick(event:MouseEvent):void {
    if (this.isOpen && !this.elementRef.nativeElement.contains(event.target)) {
      this.close();
    }
  }

  private close():void {
    this.isOpen = false;
    this.cdRef.detectChanges();
  }

  private sprintId(sprint:HalResource):string {
    return String(sprint.id);
  }

  private statusOrder(sprint:HalResource):number {
    const href = ((sprint as Record<string, unknown>).status as { href?:string }|undefined)?.href ?? '';
    if (href.endsWith(':active')) return 0;
    if (href.endsWith(':in_planning')) return 1;
    return 2; // completed
  }

  private sortSprints(sprints:HalResource[]):HalResource[] {
    return [...sprints].sort((a, b) => {
      const statusDiff = this.statusOrder(a) - this.statusOrder(b);
      if (statusDiff !== 0) return statusDiff;
      // within same status: most recent start_date first
      const aDate = (a as Record<string, unknown>).startDate as string|null ?? '';
      const bDate = (b as Record<string, unknown>).startDate as string|null ?? '';
      return bDate.localeCompare(aDate);
    });
  }

  private async loadSprintsAndAutoSelect():Promise<void> {
    const projectId = this.currentProject.id;
    if (!projectId) return;

    this.sprintsLoading = true;
    this.cdRef.detectChanges();

    try {
      const url = `/api/v3/projects/${projectId}/sprints`;
      const collection = await firstValueFrom(
        (this.apiV3Service.collectionFromString(url) as ApiV3ResourceCollection<HalResource, ApiV3Resource>)
          .filtered(new ApiV3FilterBuilder(), { pageSize: '50' })
          .get(),
      ) as CollectionResource;

      this.sprints = this.sortSprints(collection.elements as HalResource[]);
      this.hasSprintsFeature = this.sprints.length > 0;

      if (this.hasSprintsFeature) {
        const activeSprint = this.sprints.find((s) => this.isActiveSprint(s));
        const alreadyFiltered = !!this.wpTableFilters.find(SPRINT_FILTER_KEY);

        if (activeSprint && !alreadyFiltered) {
          this.selectedId = this.sprintId(activeSprint);
          try {
            this.wpTableFilters.replace(SPRINT_FILTER_KEY, (filter:QueryFilterInstanceResource) => {
              filter.operator = filter.findOperator('=')!;
              filter.values = [activeSprint];
            });
          } catch {
            this.selectedId = null;
          }
        }
      }
    } catch {
      this.sprints = [];
      this.hasSprintsFeature = false;
    } finally {
      this.sprintsLoading = false;
      this.cdRef.detectChanges();
    }
  }
}
